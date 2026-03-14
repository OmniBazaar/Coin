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

    // Verification key signer (used to complete KYC Tier 1 for referrer)
    let topLevelVerificationKey: any;

    /**
     * Helper: create EIP-712 social verification signature at top-level scope
     */
    async function createTopLevelSocialSig(
        signer: any,
        user: string,
        socialHashVal: string,
        platform: string,
        timestampVal: number,
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
        return await signer.signTypedData(domain, types, {
            user, socialHash: socialHashVal, platform,
            timestamp: timestampVal, nonce, deadline,
        });
    }

    beforeEach(async function () {
        // Get signers
        [owner, validator1, validator2, validator3, validator4, user1, user2, referrer, unauthorized] =
            await ethers.getSigners();

        const signers = await ethers.getSigners();
        topLevelVerificationKey = signers[9];

        // Deploy OmniRegistration as proxy
        const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
        registration = await upgrades.deployProxy(OmniRegistration, [], {
            initializer: 'initialize',
            kind: 'uups',
            constructorArgs: [ethers.ZeroAddress],
        });
        await registration.waitForDeployment();

        // Grant roles
        await registration.grantRole(VALIDATOR_ROLE, validator1.address);
        await registration.grantRole(VALIDATOR_ROLE, validator2.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator1.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator2.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator3.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator4.address);

        // Set trusted verification key (needed for social verification)
        await registration.connect(owner).setTrustedVerificationKey(topLevelVerificationKey.address);

        // Register referrer first (so they can be used as referrer)
        await registration.connect(validator1).registerUser(
            referrer.address,
            ZeroAddress, // No referrer for the first user
            phoneHash('+1-555-0000'),
            emailHash('referrer@test.com')
        );

        // SYBIL-H02: Complete KYC Tier 1 for referrer (phone already set, need social)
        const socialHashVal = keccak256(toUtf8Bytes('twitter:referrer_handle'));
        const currentTime = await time.latest();
        const nonce = keccak256(toUtf8Bytes('referrer-social-nonce'));
        const deadline = currentTime + 3600;
        const sig = await createTopLevelSocialSig(
            topLevelVerificationKey, referrer.address,
            socialHashVal, 'twitter', currentTime, nonce, deadline
        );
        await registration.connect(referrer).submitSocialVerificationFor(
            referrer.address, socialHashVal, 'twitter', currentTime, nonce, deadline, sig
        );
    });

    describe('Initialization', function () {
        it('should initialize with correct admin', async function () {
            expect(await registration.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it('should have correct constants', async function () {
            expect(await registration.MAX_DAILY_REGISTRATIONS()).to.equal(MAX_DAILY_REGISTRATIONS);
            expect(await registration.KYC_ATTESTATION_THRESHOLD()).to.equal(KYC_ATTESTATION_THRESHOLD);
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
            // Register user1 without phone hash (trustless flow sets phone via verification)
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash('kyc-user@test.com'),
            );

            // Complete KYC Tier 1 via trustless phone + social verification
            // so that kycTier1CompletedAt is set (required before tier 2 attestation).
            const signers = await ethers.getSigners();
            const kycAttestVerificationKey = signers[9];
            await registration.connect(owner).setTrustedVerificationKey(kycAttestVerificationKey.address);

            const registrationAddress = await registration.getAddress();
            const chainId = (await ethers.provider.getNetwork()).chainId;
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId,
                verifyingContract: registrationAddress,
            };

            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            // Phone verification
            const verifyPhoneHash = phoneHash('+1-555-2000-verify');
            const phoneNonce = keccak256(toUtf8Bytes('kyc-attest-phone-nonce'));
            const phoneSig = await kycAttestVerificationKey.signTypedData(domain, {
                PhoneVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'phoneHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            }, {
                user: user1.address,
                phoneHash: verifyPhoneHash,
                timestamp: currentTime,
                nonce: phoneNonce,
                deadline,
            });
            await registration.connect(user1).submitPhoneVerificationFor(
                user1.address, verifyPhoneHash, currentTime, phoneNonce, deadline, phoneSig
            );

            // Social verification
            const verifySocialHash = keccak256(toUtf8Bytes('twitter:kyc-attest-user'));
            const socialNonce = keccak256(toUtf8Bytes('kyc-attest-social-nonce'));
            const socialSig = await kycAttestVerificationKey.signTypedData(domain, {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            }, {
                user: user1.address,
                socialHash: verifySocialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline,
            });
            await registration.connect(user1).submitSocialVerificationFor(
                user1.address, verifySocialHash, 'twitter', currentTime, socialNonce, deadline, socialSig
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

        /**
         * Create EIP-712 email verification signature
         */
        async function createEmailVerificationSignature(
            signer: any,
            user: string,
            emailHashVal: string,
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
                EmailVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'emailHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user: user,
                emailHash: emailHashVal,
                timestamp: timestamp,
                nonce: nonce,
                deadline: deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Create EIP-712 trustless registration signature (user signature)
         */
        async function createRegistrationSignature(
            signer: any,
            user: string,
            referrerAddr: string,
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
                TrustlessRegistration: [
                    { name: 'user', type: 'address' },
                    { name: 'referrer', type: 'address' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user: user,
                referrer: referrerAddr,
                deadline: deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        beforeEach(async function () {
            // Get a dedicated verification key (distinct from validators)
            const signers = await ethers.getSigners();
            verificationKey = signers[9]; // Use signer index 9 as verification key

            // Set trusted verification key
            await registration.connect(owner).setTrustedVerificationKey(verificationKey.address);

            // Register user1 without phone hash so trustless phone verification can be tested
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                ethers.ZeroHash,
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

                const tx = await registration.connect(user2).submitPhoneVerificationFor(
                    user2.address,
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
                    registration.connect(user1).submitPhoneVerificationFor(
                        user1.address,
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
                await registration.connect(user2).submitPhoneVerificationFor(
                    user2.address,
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
                    registration.connect(user1).submitPhoneVerificationFor(
                        user1.address,
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
                    registration.connect(user1).submitPhoneVerificationFor(
                        user1.address,
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
                    constructorArgs: [ethers.ZeroAddress],
                });
                await freshRegistration.waitForDeployment();

                // Register user1 in freshRegistration so it passes the NotRegistered check
                const FRESH_VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
                await freshRegistration.grantRole(FRESH_VALIDATOR_ROLE, validator1.address);
                await freshRegistration.connect(validator1).registerUser(
                    user1.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('fresh-user@test.com')
                );

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
                    freshRegistration.connect(user1).submitPhoneVerificationFor(
                        user1.address,
                        newPhoneHash,
                        timestamp,
                        nonce,
                        deadline,
                        signature
                    )
                ).to.be.revertedWithCustomError(freshRegistration, 'TrustedVerificationKeyNotSet');
            });

            it('should reject phone hash already used', async function () {
                // First verify user1's phone so the hash is marked as used
                const existingPhoneHash = phoneHash('+1-555-7000');
                const ts1 = await time.latest();
                const nonce1 = generateNonce();
                const deadline1 = ts1 + 3600;
                const sig1 = await createPhoneVerificationSignature(
                    verificationKey,
                    user1.address,
                    existingPhoneHash,
                    ts1,
                    nonce1,
                    deadline1
                );
                await registration.connect(user1).submitPhoneVerificationFor(
                    user1.address,
                    existingPhoneHash,
                    ts1,
                    nonce1,
                    deadline1,
                    sig1
                );

                // Now try to reuse the same phone hash for user2
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
                    registration.connect(user2).submitPhoneVerificationFor(
                        user2.address,
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

                const tx = await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
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
                    registration.connect(user1).submitSocialVerificationFor(
                        user1.address,
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
                await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
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
                    registration.connect(user2).submitSocialVerificationFor(
                        user2.address,
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
                    registration.connect(user1).submitSocialVerificationFor(
                        user1.address,
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

                await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
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
                    registration.connect(user2).submitSocialVerificationFor(
                        user2.address,
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

                const tx = await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
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

                await registration.connect(user2).submitPhoneVerificationFor(
                    user2.address,
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

                await registration.connect(user2).submitSocialVerificationFor(
                    user2.address,
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

                await registration.connect(user2).submitPhoneVerificationFor(
                    user2.address,
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

                const tx = await registration.connect(user2).submitSocialVerificationFor(
                    user2.address,
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
                // Register user2 WITH a phone hash (validator-assisted path)
                const existPhone = phoneHash('+1-555-existing-phone');
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    existPhone,
                    emailHash('existing-phone@test.com')
                );

                // user2 has phone from registration, just needs social verification
                const socialHashVal = socialHash('twitter', 'existingphone');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const signature = await createSocialVerificationSignature(
                    verificationKey,
                    user2.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline
                );

                const tx = await registration.connect(user2).submitSocialVerificationFor(
                    user2.address,
                    socialHashVal,
                    platform,
                    timestamp,
                    nonce,
                    deadline,
                    signature
                );

                // Should emit KycTier1Completed since user2 already has phone verified
                await expect(tx)
                    .to.emit(registration, 'KycTier1Completed')
                    .withArgs(user2.address, await time.latest());

                expect(await registration.hasKycTier1(user2.address)).to.be.true;
            });

            it('should return false for unregistered user', async function () {
                // user2 not registered
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });
        });

        describe('selfRegisterTrustless', function () {
            it('should register with valid email proof and user signature', async function () {
                const emailHashVal = emailHash('trustless-new@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce = generateNonce();
                const emailDeadline = emailTimestamp + 3600;
                const registrationDeadline = emailTimestamp + 3600;

                // Create email verification signature from trustedVerificationKey
                const emailSignature = await createEmailVerificationSignature(
                    verificationKey,
                    user2.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline
                );

                // Create user registration signature
                const userSignature = await createRegistrationSignature(
                    user2,
                    user2.address,
                    referrer.address,
                    registrationDeadline
                );

                const tx = await registration.connect(user2).selfRegisterTrustless(
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline,
                    emailSignature,
                    referrer.address,
                    registrationDeadline,
                    userSignature
                );

                await expect(tx)
                    .to.emit(registration, 'UserRegisteredTrustless')
                    .withArgs(user2.address, referrer.address, await time.latest());

                expect(await registration.isRegistered(user2.address)).to.be.true;
                expect(await registration.getReferrer(user2.address)).to.equal(referrer.address);
            });

            it('should register without referrer', async function () {
                const emailHashVal = emailHash('no-ref-trustless@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce = generateNonce();
                const emailDeadline = emailTimestamp + 3600;
                const registrationDeadline = emailTimestamp + 3600;

                const emailSignature = await createEmailVerificationSignature(
                    verificationKey,
                    user2.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline
                );

                const userSignature = await createRegistrationSignature(
                    user2,
                    user2.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await registration.connect(user2).selfRegisterTrustless(
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline,
                    emailSignature,
                    ZeroAddress,
                    registrationDeadline,
                    userSignature
                );

                expect(await registration.isRegistered(user2.address)).to.be.true;
                expect(await registration.getReferrer(user2.address)).to.equal(ZeroAddress);
            });

            it('should reject expired email proof', async function () {
                const emailHashVal = emailHash('expired-email@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce = generateNonce();
                const emailDeadline = emailTimestamp + 1; // Expires in 1 second
                const registrationDeadline = emailTimestamp + 3600;

                const emailSignature = await createEmailVerificationSignature(
                    verificationKey,
                    user2.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline
                );

                const userSignature = await createRegistrationSignature(
                    user2,
                    user2.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await time.increase(2);

                await expect(
                    registration.connect(user2).selfRegisterTrustless(
                        emailHashVal,
                        emailTimestamp,
                        emailNonce,
                        emailDeadline,
                        emailSignature,
                        ZeroAddress,
                        registrationDeadline,
                        userSignature
                    )
                ).to.be.revertedWithCustomError(registration, 'ProofExpired');
            });

            it('should reject invalid email signature', async function () {
                const emailHashVal = emailHash('invalid-sig@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce = generateNonce();
                const emailDeadline = emailTimestamp + 3600;
                const registrationDeadline = emailTimestamp + 3600;

                // Sign with wrong key (unauthorized instead of verificationKey)
                const emailSignature = await createEmailVerificationSignature(
                    unauthorized,
                    user2.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline
                );

                const userSignature = await createRegistrationSignature(
                    user2,
                    user2.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await expect(
                    registration.connect(user2).selfRegisterTrustless(
                        emailHashVal,
                        emailTimestamp,
                        emailNonce,
                        emailDeadline,
                        emailSignature,
                        ZeroAddress,
                        registrationDeadline,
                        userSignature
                    )
                ).to.be.revertedWithCustomError(registration, 'InvalidVerificationProof');
            });

            it('should reject invalid user signature', async function () {
                const emailHashVal = emailHash('bad-user-sig@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce = generateNonce();
                const emailDeadline = emailTimestamp + 3600;
                const registrationDeadline = emailTimestamp + 3600;

                const emailSignature = await createEmailVerificationSignature(
                    verificationKey,
                    user2.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline
                );

                // Sign with wrong user (unauthorized instead of user2)
                const userSignature = await createRegistrationSignature(
                    unauthorized,
                    user2.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await expect(
                    registration.connect(user2).selfRegisterTrustless(
                        emailHashVal,
                        emailTimestamp,
                        emailNonce,
                        emailDeadline,
                        emailSignature,
                        ZeroAddress,
                        registrationDeadline,
                        userSignature
                    )
                ).to.be.revertedWithCustomError(registration, 'InvalidUserSignature');
            });

            it('should reject duplicate email hash', async function () {
                const emailHashVal = emailHash('duplicate-email@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce1 = generateNonce();
                const emailDeadline = emailTimestamp + 3600;
                const registrationDeadline = emailTimestamp + 3600;

                // First registration
                const emailSig1 = await createEmailVerificationSignature(
                    verificationKey,
                    user2.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce1,
                    emailDeadline
                );

                const userSig1 = await createRegistrationSignature(
                    user2,
                    user2.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await registration.connect(user2).selfRegisterTrustless(
                    emailHashVal,
                    emailTimestamp,
                    emailNonce1,
                    emailDeadline,
                    emailSig1,
                    ZeroAddress,
                    registrationDeadline,
                    userSig1
                );

                // Second registration attempt with same email
                const signers = await ethers.getSigners();
                const user3 = signers[10];
                const emailNonce2 = generateNonce();

                const emailSig2 = await createEmailVerificationSignature(
                    verificationKey,
                    user3.address,
                    emailHashVal, // Same email
                    emailTimestamp,
                    emailNonce2,
                    emailDeadline
                );

                const userSig2 = await createRegistrationSignature(
                    user3,
                    user3.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await expect(
                    registration.connect(user3).selfRegisterTrustless(
                        emailHashVal,
                        emailTimestamp,
                        emailNonce2,
                        emailDeadline,
                        emailSig2,
                        ZeroAddress,
                        registrationDeadline,
                        userSig2
                    )
                ).to.be.revertedWithCustomError(registration, 'EmailAlreadyUsed');
            });

            it('should reject already registered user', async function () {
                const emailHashVal = emailHash('already-reg@test.com');
                const emailTimestamp = await time.latest();
                const emailNonce = generateNonce();
                const emailDeadline = emailTimestamp + 3600;
                const registrationDeadline = emailTimestamp + 3600;

                // user1 is already registered in beforeEach
                const emailSignature = await createEmailVerificationSignature(
                    verificationKey,
                    user1.address,
                    emailHashVal,
                    emailTimestamp,
                    emailNonce,
                    emailDeadline
                );

                const userSignature = await createRegistrationSignature(
                    user1,
                    user1.address,
                    ZeroAddress,
                    registrationDeadline
                );

                await expect(
                    registration.connect(user1).selfRegisterTrustless(
                        emailHashVal,
                        emailTimestamp,
                        emailNonce,
                        emailDeadline,
                        emailSignature,
                        ZeroAddress,
                        registrationDeadline,
                        userSignature
                    )
                ).to.be.revertedWithCustomError(registration, 'AlreadyRegistered');
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

    // ═══════════════════════════════════════════════════════════════════════
    //                   KYC TIER 2/3/4 TESTS
    // ═══════════════════════════════════════════════════════════════════════

    describe('KYC Tier 2 - ID Verification', function () {
        let trustedKey: any;
        let tier2Email: string;

        /**
         * Generate ID verification signature
         */
        async function signIDVerification(
            signer: any,
            user: string,
            idHash: string,
            country: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            const types = {
                IDVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'idHash', type: 'bytes32' },
                    { name: 'country', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user,
                idHash,
                country,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        beforeEach(async function () {
            // Use validator3 as trusted verification key
            trustedKey = validator3;
            await registration.connect(owner).setTrustedVerificationKey(trustedKey.address);

            // Generate truly unique identifiers
            const uniqueId = Date.now().toString() + Math.random().toString().slice(2, 8);
            tier2Email = `kyc-tier2-${uniqueId}@test.com`;

            // Register user1 without phone hash (trustless flow sets phone via verification)
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                ethers.ZeroHash,
                emailHash(tier2Email)
            );

            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            // Complete KYC Tier 1: Phone verification
            const verificationPhone = `+1-TIER2-VERIFY-${uniqueId}`;
            const phoneNonce = keccak256(toUtf8Bytes(`phone-nonce-tier2-${uniqueId}`));
            const phoneSig = await signPhoneVerification(
                trustedKey,
                user1.address,
                phoneHash(verificationPhone),
                currentTime,
                phoneNonce,
                deadline
            );
            await registration.connect(user1).submitPhoneVerificationFor(
                user1.address,
                phoneHash(verificationPhone),
                currentTime,
                phoneNonce,
                deadline,
                phoneSig
            );

            // Complete KYC Tier 1: Social verification (REQUIRED for Tier 1 completion)
            const socialHash = keccak256(toUtf8Bytes(`twitter:tier2user-${uniqueId}`));
            const socialNonce = keccak256(toUtf8Bytes(`social-nonce-tier2-${uniqueId}`));
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };
            const socialTypes = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const socialSig = await trustedKey.signTypedData(domain, socialTypes, {
                user: user1.address,
                socialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline,
            });
            await registration.connect(user1).submitSocialVerificationFor(
                user1.address,
                socialHash,
                'twitter',
                currentTime,
                socialNonce,
                deadline,
                socialSig
            );
        });

        /**
         * Generate phone verification signature for KYC Tier 1
         */
        async function signPhoneVerification(
            signer: any,
            user: string,
            phoneHashVal: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
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
                user,
                phoneHash: phoneHashVal,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        it('should complete ID verification (KYC Tier 2)', async function () {
            const idHash = keccak256(toUtf8Bytes('PASSPORT:AB123456:1990-01-01:US'));
            const country = 'US';
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('id-nonce-1'));
            const deadline = currentTime + 3600;

            const signature = await signIDVerification(
                trustedKey,
                user1.address,
                idHash,
                country,
                currentTime,
                nonce,
                deadline
            );

            const tx = await registration.connect(user1).submitIDVerificationFor(
                user1.address,
                idHash,
                country,
                currentTime,
                nonce,
                deadline,
                signature
            );

            // ID verification should succeed but NOT complete Tier 2 yet
            await expect(tx).to.emit(registration, 'IDVerified');
            // KycTier2Completed should NOT be emitted (need address too)

            // Tier 2 should NOT be complete after just ID
            expect(await registration.hasKycTier2(user1.address)).to.be.false;
            expect(await registration.kycTier2CompletedAt(user1.address)).to.equal(0);
        });

        it('should reject ID verification without KYC Tier 1', async function () {
            // Register user2 so the NotRegistered check passes, but do NOT
            // complete KYC Tier 1 (phone+social via trustless path) so
            // kycTier1CompletedAt remains 0 and PreviousTierRequired is hit.
            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                phoneHash('+1-555-TIER2-NOKYC'),
                emailHash('tier2-nokyc@test.com')
            );

            const idHash = keccak256(toUtf8Bytes('PASSPORT:AB123457:1990-01-01:US'));
            const country = 'US';
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('id-nonce-2'));
            const deadline = currentTime + 3600;

            const signature = await signIDVerification(
                trustedKey,
                user2.address,
                idHash,
                country,
                currentTime,
                nonce,
                deadline
            );

            await expect(
                registration.connect(user2).submitIDVerificationFor(
                    user2.address,
                    idHash,
                    country,
                    currentTime,
                    nonce,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'PreviousTierRequired');
        });

        it('should reject ID verification with expired deadline', async function () {
            const idHash = keccak256(toUtf8Bytes('PASSPORT:AB123458:1990-01-01:US'));
            const country = 'US';
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('id-nonce-3'));
            const deadline = currentTime - 1; // Expired

            const signature = await signIDVerification(
                trustedKey,
                user1.address,
                idHash,
                country,
                currentTime,
                nonce,
                deadline
            );

            await expect(
                registration.connect(user1).submitIDVerificationFor(
                    user1.address,
                    idHash,
                    country,
                    currentTime,
                    nonce,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'ProofExpired');
        });

        it('should reject duplicate ID hash', async function () {
            const idHash = keccak256(toUtf8Bytes('PASSPORT:DUPLICATE:1990-01-01:US'));
            const country = 'US';
            const currentTime = await time.latest();
            const nonce1 = keccak256(toUtf8Bytes('id-nonce-4'));
            const deadline = currentTime + 3600;

            // First verification
            const sig1 = await signIDVerification(
                trustedKey,
                user1.address,
                idHash,
                country,
                currentTime,
                nonce1,
                deadline
            );

            await registration.connect(user1).submitIDVerificationFor(
                user1.address,
                idHash,
                country,
                currentTime,
                nonce1,
                deadline,
                sig1
            );

            // Register and setup user2 for KYC tier 1 (unique identifiers)
            const dupIdUnique = Date.now().toString() + Math.random().toString().slice(2, 8);
            const dupVerifyPhone = `+1-DUP-VERIFY-${dupIdUnique}`;

            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash(`kyc-dupid-user2-${dupIdUnique}@test.com`)
            );

            const nonce2 = keccak256(toUtf8Bytes(`phone-nonce-dupid-${dupIdUnique}`));
            const phoneSig = await signPhoneVerification(
                trustedKey,
                user2.address,
                phoneHash(dupVerifyPhone),
                currentTime,
                nonce2,
                deadline
            );

            await registration.connect(user2).submitPhoneVerificationFor(
                user2.address,
                phoneHash(dupVerifyPhone),
                currentTime,
                nonce2,
                deadline,
                phoneSig
            );

            // Complete social verification (required for Tier 1 completion)
            const socialDomain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };
            const socialTypes = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const socialHash = keccak256(toUtf8Bytes(`twitter:dupid-user-${dupIdUnique}`));
            const socialNonce = keccak256(toUtf8Bytes(`social-dupid-${dupIdUnique}`));
            const socialSig = await trustedKey.signTypedData(socialDomain, socialTypes, {
                user: user2.address,
                socialHash: socialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline: deadline,
            });
            await registration.connect(user2).submitSocialVerificationFor(
                user2.address,
                socialHash,
                'twitter',
                currentTime,
                socialNonce,
                deadline,
                socialSig
            );

            // Try to use same ID hash
            const nonce3 = keccak256(toUtf8Bytes('id-nonce-5'));
            const sig2 = await signIDVerification(
                trustedKey,
                user2.address,
                idHash, // Same ID
                country,
                currentTime,
                nonce3,
                deadline
            );

            await expect(
                registration.connect(user2).submitIDVerificationFor(
                    user2.address,
                    idHash,
                    country,
                    currentTime,
                    nonce3,
                    deadline,
                    sig2
                )
            ).to.be.revertedWithCustomError(registration, 'IDAlreadyUsed');
        });

        it('should verify hasKycTier2 returns false before verification', async function () {
            expect(await registration.hasKycTier2(user1.address)).to.be.false;
        });
    });

    describe('KYC Tier 3 - Persona + AML Verification', function () {
        let trustedKey: any;

        /**
         * Generate Persona verification signature
         */
        async function signPersonaVerification(
            signer: any,
            user: string,
            verificationHash: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            const types = {
                PersonaVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'verificationHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user,
                verificationHash,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Generate AML clearance signature
         */
        async function signAMLClearance(
            signer: any,
            user: string,
            cleared: boolean,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            const types = {
                AMLClearance: [
                    { name: 'user', type: 'address' },
                    { name: 'cleared', type: 'bool' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user,
                cleared,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Generate accredited investor certification signature
         */
        async function signAccreditedInvestorCertification(
            signer: any,
            user: string,
            criteria: number,
            certified: boolean,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            const types = {
                AccreditedInvestorCertification: [
                    { name: 'user', type: 'address' },
                    { name: 'criteria', type: 'uint8' },
                    { name: 'certified', type: 'bool' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user,
                criteria,
                certified,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Generate phone verification signature
         */
        async function signPhoneVerification(
            signer: any,
            user: string,
            phoneHashVal: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
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
                user,
                phoneHash: phoneHashVal,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Generate ID verification signature
         */
        async function signIDVerification(
            signer: any,
            user: string,
            idHash: string,
            country: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            const types = {
                IDVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'idHash', type: 'bytes32' },
                    { name: 'country', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user,
                idHash,
                country,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        beforeEach(async function () {
            trustedKey = validator3;
            await registration.connect(owner).setTrustedVerificationKey(trustedKey.address);

            // Generate truly unique identifiers
            const uniqueId = Date.now().toString() + Math.random().toString().slice(2, 8);
            const regEmail = `kyc-tier3-${uniqueId}@test.com`;
            const verifyPhone = `+1-TIER3-VERIFY-${uniqueId}`;

            // Register user1 without phone hash (trustless flow sets phone via verification)
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                ethers.ZeroHash,
                emailHash(regEmail)
            );

            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            // Complete Tier 1 - Phone verification
            const phoneNonce = keccak256(toUtf8Bytes(`tier3-phone-nonce-${uniqueId}`));
            const phoneSig = await signPhoneVerification(
                trustedKey,
                user1.address,
                phoneHash(verifyPhone),
                currentTime,
                phoneNonce,
                deadline
            );
            await registration.connect(user1).submitPhoneVerificationFor(
                user1.address,
                phoneHash(verifyPhone),
                currentTime,
                phoneNonce,
                deadline,
                phoneSig
            );

            // Complete Tier 1 - Social verification (REQUIRED)
            const socialHash = keccak256(toUtf8Bytes(`twitter:tier3user-${uniqueId}`));
            const socialNonce = keccak256(toUtf8Bytes(`tier3-social-nonce-${uniqueId}`));
            const socialTypes = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const socialSig = await trustedKey.signTypedData(domain, socialTypes, {
                user: user1.address,
                socialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline,
            });
            await registration.connect(user1).submitSocialVerificationFor(
                user1.address,
                socialHash,
                'twitter',
                currentTime,
                socialNonce,
                deadline,
                socialSig
            );

            // Complete Tier 2 - ID verification
            const idHash = keccak256(toUtf8Bytes(`PASSPORT:TIER3-${uniqueId}:1990-01-01:US`));
            const idNonce = keccak256(toUtf8Bytes(`tier3-id-nonce-${uniqueId}`));
            const idSig = await signIDVerification(
                trustedKey,
                user1.address,
                idHash,
                'US',
                currentTime,
                idNonce,
                deadline
            );
            await registration.connect(user1).submitIDVerificationFor(
                user1.address,
                idHash,
                'US',
                currentTime,
                idNonce,
                deadline,
                idSig
            );

            // Complete Tier 2 - Address verification (required)
            const addressHash = keccak256(toUtf8Bytes(`123 Main:NYC:10001:US:utility-${uniqueId}`));
            const addressNonce = keccak256(toUtf8Bytes(`tier3-addr-${uniqueId}`));
            const addressTypes = {
                AddressVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'addressHash', type: 'bytes32' },
                    { name: 'country', type: 'string' },
                    { name: 'documentType', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const addressSig = await trustedKey.signTypedData(domain, addressTypes, {
                user: user1.address,
                addressHash,
                country: 'US',
                documentType: keccak256(toUtf8Bytes('utility')),
                timestamp: currentTime,
                nonce: addressNonce,
                deadline,
            });
            await registration.connect(user1).submitAddressVerificationFor(
                user1.address,
                addressHash,
                'US',
                keccak256(toUtf8Bytes('utility')),
                currentTime,
                addressNonce,
                deadline,
                addressSig
            );

            // Tier 2 should now be complete (ID + address, no selfie required)
        });

        it('should complete Persona verification', async function () {
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_12345:passed'));
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('persona-nonce-1'));
            const deadline = currentTime + 3600;

            const signature = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                nonce,
                deadline
            );

            const tx = await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                nonce,
                deadline,
                signature
            );

            await expect(tx)
                .to.emit(registration, 'PersonaVerified')
                .withArgs(user1.address, verificationHash, currentTime);

            expect(await registration.personaVerificationHashes(user1.address))
                .to.equal(verificationHash);

            // Tier 3 should NOT be complete (AML also needed)
            expect(await registration.hasKycTier3(user1.address)).to.be.false;
        });

        it('should complete AML clearance', async function () {
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('aml-nonce-1'));
            const deadline = currentTime + 3600;

            const signature = await signAMLClearance(
                trustedKey,
                user1.address,
                true,
                currentTime,
                nonce,
                deadline
            );

            const tx = await registration.connect(owner).submitAMLClearance(
                user1.address,
                true,
                currentTime,
                nonce,
                deadline,
                signature
            );

            await expect(tx)
                .to.emit(registration, 'AMLCleared')
                .withArgs(user1.address, true, currentTime);

            expect(await registration.amlCleared(user1.address)).to.be.true;
            expect(await registration.amlClearedAt(user1.address)).to.be.gt(0);

            // Tier 3 should NOT be complete (Persona also needed)
            expect(await registration.hasKycTier3(user1.address)).to.be.false;
        });

        it('should complete Tier 3 when both Persona and AML are done', async function () {
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            // Step 1: Submit Persona verification
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_FULL:passed'));
            const personaNonce = keccak256(toUtf8Bytes('persona-nonce-full'));

            const personaSig = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline
            );

            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            // Step 2: Submit AML clearance (should trigger Tier 3 completion)
            const amlNonce = keccak256(toUtf8Bytes('aml-nonce-full'));
            const amlSig = await signAMLClearance(
                trustedKey,
                user1.address,
                true,
                currentTime,
                amlNonce,
                deadline
            );

            const tx = await registration.connect(owner).submitAMLClearance(
                user1.address,
                true,
                currentTime,
                amlNonce,
                deadline,
                amlSig
            );

            // Should emit both AMLCleared and KycTier3Completed + KYCUpgraded
            await expect(tx)
                .to.emit(registration, 'AMLCleared')
                .withArgs(user1.address, true, currentTime);
            await expect(tx).to.emit(registration, 'KycTier3Completed');
            await expect(tx)
                .to.emit(registration, 'KYCUpgraded')
                .withArgs(user1.address, 2, 3);

            // Verify Tier 3 is complete
            expect(await registration.kycTier3CompletedAt(user1.address)).to.be.gt(0);
            expect(await registration.hasKycTier3(user1.address)).to.be.true;
            expect(await registration.getUserKYCTier(user1.address)).to.equal(3);
        });

        it('should NOT complete Tier 3 with only Persona', async function () {
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_ONLY:passed'));
            const nonce = keccak256(toUtf8Bytes('persona-nonce-only'));

            const signature = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                nonce,
                deadline
            );

            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                nonce,
                deadline,
                signature
            );

            // Tier 3 should NOT be complete
            expect(await registration.kycTier3CompletedAt(user1.address)).to.equal(0);
            expect(await registration.hasKycTier3(user1.address)).to.be.false;
            expect(await registration.getUserKYCTier(user1.address)).to.equal(2);
        });

        it('should NOT complete Tier 3 with only AML', async function () {
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const nonce = keccak256(toUtf8Bytes('aml-nonce-only'));

            const signature = await signAMLClearance(
                trustedKey,
                user1.address,
                true,
                currentTime,
                nonce,
                deadline
            );

            await registration.connect(owner).submitAMLClearance(
                user1.address,
                true,
                currentTime,
                nonce,
                deadline,
                signature
            );

            // Tier 3 should NOT be complete (no Persona)
            expect(await registration.kycTier3CompletedAt(user1.address)).to.equal(0);
            expect(await registration.hasKycTier3(user1.address)).to.be.false;
            expect(await registration.getUserKYCTier(user1.address)).to.equal(2);
        });

        it('should reject Persona verification without Tier 2', async function () {
            // Register user2 with only Tier 1 (unique identifiers)
            const noTier2Unique = Date.now().toString() + Math.random().toString().slice(2, 8);
            const noTier2VerifyPhone = `+1-NOTIER2-VERIFY-${noTier2Unique}`;

            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash(`kyc-notier2-user2-${noTier2Unique}@test.com`)
            );

            const currentTime = await time.latest();
            const deadline = currentTime + 3600;
            const phoneNonce = keccak256(toUtf8Bytes(`tier3-phone-nonce-${noTier2Unique}`));
            const phoneSig = await signPhoneVerification(
                trustedKey,
                user2.address,
                phoneHash(noTier2VerifyPhone),
                currentTime,
                phoneNonce,
                deadline
            );
            await registration.connect(user2).submitPhoneVerificationFor(
                user2.address,
                phoneHash(noTier2VerifyPhone),
                currentTime,
                phoneNonce,
                deadline,
                phoneSig
            );

            // Complete social verification (required for Tier 1)
            const socialDomain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };
            const socialTypes = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const socialHash = keccak256(toUtf8Bytes(`twitter:notier2-user-${noTier2Unique}`));
            const socialNonce = keccak256(toUtf8Bytes(`social-notier2-${noTier2Unique}`));
            const socialSig = await trustedKey.signTypedData(socialDomain, socialTypes, {
                user: user2.address,
                socialHash: socialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline: deadline,
            });
            await registration.connect(user2).submitSocialVerificationFor(
                user2.address,
                socialHash,
                'twitter',
                currentTime,
                socialNonce,
                deadline,
                socialSig
            );

            // Try Persona verification without Tier 2
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_NO_TIER2'));
            const nonce = keccak256(toUtf8Bytes('persona-nonce-notier2'));
            const signature = await signPersonaVerification(
                trustedKey,
                user2.address,
                verificationHash,
                currentTime,
                nonce,
                deadline
            );

            await expect(
                registration.connect(user2).submitPersonaVerificationFor(
                    user2.address,
                    verificationHash,
                    currentTime,
                    nonce,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'PreviousTierRequired');
        });

        it('should allow submitPersonaVerificationFor (relay)', async function () {
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_RELAY:passed'));
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('persona-nonce-relay'));
            const deadline = currentTime + 3600;

            const signature = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                nonce,
                deadline
            );

            // Submit via relay (unauthorized submitter, but valid signature for user1)
            const tx = await registration.connect(unauthorized).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                nonce,
                deadline,
                signature
            );

            await expect(tx)
                .to.emit(registration, 'PersonaVerified')
                .withArgs(user1.address, verificationHash, currentTime);

            expect(await registration.personaVerificationHashes(user1.address))
                .to.equal(verificationHash);
        });

        it('should reject AML clearance with cleared=false', async function () {
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const nonce = keccak256(toUtf8Bytes('aml-nonce-false'));

            const signature = await signAMLClearance(
                trustedKey,
                user1.address,
                false,
                currentTime,
                nonce,
                deadline
            );

            const tx = await registration.connect(owner).submitAMLClearance(
                user1.address,
                false,
                currentTime,
                nonce,
                deadline,
                signature
            );

            await expect(tx)
                .to.emit(registration, 'AMLCleared')
                .withArgs(user1.address, false, currentTime);

            expect(await registration.amlCleared(user1.address)).to.be.false;

            // Tier 3 should NOT be completed even with Persona (AML not cleared)
            // Submit Persona first
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_AML_FALSE'));
            const personaNonce = keccak256(toUtf8Bytes('persona-nonce-aml-false'));
            const personaSig = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline
            );
            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            expect(await registration.kycTier3CompletedAt(user1.address)).to.equal(0);
            expect(await registration.hasKycTier3(user1.address)).to.be.false;
        });

        it('should submit accredited investor as accredited', async function () {
            // First complete Persona verification (required for accredited investor)
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_ACCREDITED'));
            const personaNonce = keccak256(toUtf8Bytes('persona-nonce-accredited'));
            const personaSig = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline
            );
            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            // Submit accredited investor certification
            const criteria = 0x03; // Example: income + net worth criteria
            const nonce = keccak256(toUtf8Bytes('accredited-nonce-1'));
            const signature = await signAccreditedInvestorCertification(
                trustedKey,
                user1.address,
                criteria,
                true,
                currentTime,
                nonce,
                deadline
            );

            const tx = await registration.connect(user1).submitAccreditedInvestorCertificationFor(
                    user1.address,
                criteria,
                true,
                currentTime,
                nonce,
                deadline,
                signature
            );

            await expect(tx).to.emit(registration, 'AccreditedInvestorCertified');

            expect(await registration.isAccreditedInvestor(user1.address)).to.be.true;
            expect(await registration.accreditedInvestorCriteria(user1.address)).to.equal(3);
        });

        it('should submit accredited investor as NOT accredited', async function () {
            // First complete Persona verification (required)
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_NOT_ACCREDITED'));
            const personaNonce = keccak256(toUtf8Bytes('persona-nonce-not-accredited'));
            const personaSig = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline
            );
            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            // Submit as NOT accredited
            const nonce = keccak256(toUtf8Bytes('accredited-nonce-not'));
            const signature = await signAccreditedInvestorCertification(
                trustedKey,
                user1.address,
                0,
                false,
                currentTime,
                nonce,
                deadline
            );

            await registration.connect(user1).submitAccreditedInvestorCertificationFor(
                    user1.address,
                0,
                false,
                currentTime,
                nonce,
                deadline,
                signature
            );

            expect(await registration.isAccreditedInvestor(user1.address)).to.be.false;
            expect(await registration.accreditedInvestorCriteria(user1.address)).to.equal(0);
        });

        it('should reject accredited investor without Persona', async function () {
            // user1 has Tier 2 but no Persona verification yet
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const nonce = keccak256(toUtf8Bytes('accredited-nonce-no-persona'));
            const signature = await signAccreditedInvestorCertification(
                trustedKey,
                user1.address,
                0x03,
                true,
                currentTime,
                nonce,
                deadline
            );

            await expect(
                registration.connect(user1).submitAccreditedInvestorCertificationFor(
                    user1.address,
                    0x03,
                    true,
                    currentTime,
                    nonce,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'PreviousTierRequired');
        });

        it('should resetKycTier3', async function () {
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            // Complete Tier 3: Persona + AML
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_RESET'));
            const personaNonce = keccak256(toUtf8Bytes('persona-nonce-reset'));
            const personaSig = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline
            );
            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            const amlNonce = keccak256(toUtf8Bytes('aml-nonce-reset'));
            const amlSig = await signAMLClearance(
                trustedKey,
                user1.address,
                true,
                currentTime,
                amlNonce,
                deadline
            );
            await registration.connect(owner).submitAMLClearance(
                user1.address,
                true,
                currentTime,
                amlNonce,
                deadline,
                amlSig
            );

            // Verify Tier 3 is complete
            expect(await registration.hasKycTier3(user1.address)).to.be.true;
            expect(await registration.getUserKYCTier(user1.address)).to.equal(3);

            // Admin resets Tier 3
            const tx = await registration.connect(owner).resetKycTier3(user1.address);

            await expect(tx)
                .to.emit(registration, 'KYCUpgraded')
                .withArgs(user1.address, 3, 2);
            await expect(tx).to.emit(registration, 'KycTier3Reset');

            // Verify reset
            expect(await registration.kycTier3CompletedAt(user1.address)).to.equal(0);
            expect(await registration.personaVerificationHashes(user1.address))
                .to.equal(ethers.ZeroHash);
            expect(await registration.amlCleared(user1.address)).to.be.false;
            expect(await registration.getUserKYCTier(user1.address)).to.equal(2);
        });

        it('resetKycTier3 should also reset Tier 4 if present', async function () {
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            // Complete Tier 3: Persona + AML
            const verificationHash = keccak256(toUtf8Bytes('PERSONA_INQ_RESET_T4'));
            const personaNonce = keccak256(toUtf8Bytes('persona-nonce-reset-t4'));
            const personaSig = await signPersonaVerification(
                trustedKey,
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline
            );
            await registration.connect(user1).submitPersonaVerificationFor(
                user1.address,
                verificationHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            const amlNonce = keccak256(toUtf8Bytes('aml-nonce-reset-t4'));
            const amlSig = await signAMLClearance(
                trustedKey,
                user1.address,
                true,
                currentTime,
                amlNonce,
                deadline
            );
            await registration.connect(owner).submitAMLClearance(
                user1.address,
                true,
                currentTime,
                amlNonce,
                deadline,
                amlSig
            );

            // Complete Tier 4: Third-party KYC
            await registration.connect(owner).addKYCProvider(validator4.address, 'TestProvider');

            const kycNonce = keccak256(toUtf8Bytes('kyc-tier4-reset-nonce'));
            const kycDomain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };
            const kycTypes = {
                ThirdPartyKYC: [
                    { name: 'user', type: 'address' },
                    { name: 'provider', type: 'address' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const kycSig = await validator4.signTypedData(kycDomain, kycTypes, {
                user: user1.address,
                provider: validator4.address,
                timestamp: currentTime,
                nonce: kycNonce,
                deadline,
            });
            await registration.connect(user1).submitThirdPartyKYCFor(
                user1.address,
                validator4.address,
                currentTime,
                kycNonce,
                deadline,
                kycSig
            );

            // Verify Tier 4 is complete
            expect(await registration.hasKycTier4(user1.address)).to.be.true;
            expect(await registration.getUserKYCTier(user1.address)).to.equal(4);

            // Admin resets Tier 3 (should also reset Tier 4)
            const tx = await registration.connect(owner).resetKycTier3(user1.address);

            await expect(tx)
                .to.emit(registration, 'KYCUpgraded')
                .withArgs(user1.address, 4, 2);
            await expect(tx).to.emit(registration, 'KycTier3Reset');

            // Verify both Tier 3 and Tier 4 are reset
            expect(await registration.kycTier3CompletedAt(user1.address)).to.equal(0);
            expect(await registration.kycTier4CompletedAt(user1.address)).to.equal(0);
            expect(await registration.getUserKYCTier(user1.address)).to.equal(2);
        });

        it('should reject resetKycTier3 from non-admin', async function () {
            await expect(
                registration.connect(unauthorized).resetKycTier3(user1.address)
            ).to.be.reverted;
        });

        it('should verify hasKycTier3 returns false before verification', async function () {
            expect(await registration.hasKycTier3(user1.address)).to.be.false;
        });
    });

    describe('KYC Tier 4 - Third-Party KYC', function () {
        let trustedKey: any;
        let kycProvider: any;

        /**
         * Generate third-party KYC signature
         */
        async function signThirdPartyKYC(
            signer: any,
            user: string,
            provider: string,
            timestamp: number,
            nonce: string,
            deadline: number
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            const types = {
                ThirdPartyKYC: [
                    { name: 'user', type: 'address' },
                    { name: 'provider', type: 'address' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user,
                provider,
                timestamp,
                nonce,
                deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        /**
         * Setup user with Tier 1, 2, and 3 using unique identifiers
         */
        async function setupUserWithTier3(user: any): Promise<void> {
            // Generate truly unique identifiers
            const uniqueId = Date.now().toString() + Math.random().toString().slice(2, 8);
            const regEmail = `kyc-tier4-${uniqueId}@test.com`;
            const verifyPhone = `+1-TIER4-VERIFY-${uniqueId}`;

            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            // Register without phone hash (trustless flow sets phone via verification)
            await registration.connect(validator1).registerUser(
                user.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash(regEmail)
            );

            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            // Phone verification (Tier 1)
            const phoneNonce = keccak256(toUtf8Bytes(`tier4-phone-${uniqueId}`));
            const phoneTypes = {
                PhoneVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'phoneHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const phoneSig = await trustedKey.signTypedData(domain, phoneTypes, {
                user: user.address,
                phoneHash: phoneHash(verifyPhone),
                timestamp: currentTime,
                nonce: phoneNonce,
                deadline,
            });
            await registration.connect(user).submitPhoneVerificationFor(
                user.address,
                phoneHash(verifyPhone),
                currentTime,
                phoneNonce,
                deadline,
                phoneSig
            );

            // Social verification (Tier 1 completion - REQUIRED)
            const socialHash = keccak256(toUtf8Bytes(`twitter:tier4user-${uniqueId}`));
            const socialNonce = keccak256(toUtf8Bytes(`tier4-social-${uniqueId}`));
            const socialTypes = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const socialSig = await trustedKey.signTypedData(domain, socialTypes, {
                user: user.address,
                socialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline,
            });
            await registration.connect(user).submitSocialVerificationFor(
                user.address,
                socialHash,
                'twitter',
                currentTime,
                socialNonce,
                deadline,
                socialSig
            );

            // ID verification (Tier 2)
            const idHash = keccak256(toUtf8Bytes(`PASSPORT:TIER4-${uniqueId}:1990-01-01:US`));
            const idNonce = keccak256(toUtf8Bytes(`tier4-id-${uniqueId}`));
            const idTypes = {
                IDVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'idHash', type: 'bytes32' },
                    { name: 'country', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const idSig = await trustedKey.signTypedData(domain, idTypes, {
                user: user.address,
                idHash,
                country: 'US',
                timestamp: currentTime,
                nonce: idNonce,
                deadline,
            });
            await registration.connect(user).submitIDVerificationFor(
                user.address,
                idHash,
                'US',
                currentTime,
                idNonce,
                deadline,
                idSig
            );

            // Address verification (Tier 2 requirement)
            const addressHash = keccak256(toUtf8Bytes(`123 Main:NYC:10001:US:utility-${uniqueId}`));
            const addressNonce = keccak256(toUtf8Bytes(`tier4-addr-${uniqueId}`));
            const addressTypes = {
                AddressVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'addressHash', type: 'bytes32' },
                    { name: 'country', type: 'string' },
                    { name: 'documentType', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const addressSig = await trustedKey.signTypedData(domain, addressTypes, {
                user: user.address,
                addressHash,
                country: 'US',
                documentType: keccak256(toUtf8Bytes('utility')),
                timestamp: currentTime,
                nonce: addressNonce,
                deadline,
            });
            await registration.connect(user).submitAddressVerificationFor(
                user.address,
                addressHash,
                'US',
                keccak256(toUtf8Bytes('utility')),
                currentTime,
                addressNonce,
                deadline,
                addressSig
            );

            // Tier 2 complete (ID + address, no selfie required)

            // Persona verification (Tier 3 step 1)
            const personaHash = keccak256(toUtf8Bytes(`PERSONA_INQ_TIER4_${uniqueId}`));
            const personaNonce = keccak256(toUtf8Bytes(`tier4-persona-${uniqueId}`));
            const personaTypes = {
                PersonaVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'verificationHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const personaSig = await trustedKey.signTypedData(domain, personaTypes, {
                user: user.address,
                verificationHash: personaHash,
                timestamp: currentTime,
                nonce: personaNonce,
                deadline,
            });
            await registration.connect(user).submitPersonaVerificationFor(
                user.address,
                personaHash,
                currentTime,
                personaNonce,
                deadline,
                personaSig
            );

            // AML clearance (Tier 3 step 2)
            const amlNonce = keccak256(toUtf8Bytes(`tier4-aml-${uniqueId}`));
            const amlTypes = {
                AMLClearance: [
                    { name: 'user', type: 'address' },
                    { name: 'cleared', type: 'bool' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const amlSig = await trustedKey.signTypedData(domain, amlTypes, {
                user: user.address,
                cleared: true,
                timestamp: currentTime,
                nonce: amlNonce,
                deadline,
            });
            await registration.connect(owner).submitAMLClearance(
                user.address,
                true,
                currentTime,
                amlNonce,
                deadline,
                amlSig
            );

            // Tier 3 complete (Persona + AML)
        }

        beforeEach(async function () {
            trustedKey = validator3;
            kycProvider = validator4;

            await registration.connect(owner).setTrustedVerificationKey(trustedKey.address);
            await registration.connect(owner).addKYCProvider(kycProvider.address, 'TestKYCProvider');

            // Setup user1 with Tier 3 using unique identifiers
            await setupUserWithTier3(user1);
        });

        it('should complete third-party KYC (KYC Tier 4)', async function () {
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('kyc-tier4-nonce-1'));
            const deadline = currentTime + 3600;

            const signature = await signThirdPartyKYC(
                kycProvider,
                user1.address,
                kycProvider.address,
                currentTime,
                nonce,
                deadline
            );

            const tx = await registration.connect(user1).submitThirdPartyKYCFor(
                user1.address,
                kycProvider.address,
                currentTime,
                nonce,
                deadline,
                signature
            );

            await expect(tx).to.emit(registration, 'KycTier4Completed');

            expect(await registration.hasKycTier4(user1.address)).to.be.true;
        });

        it('should reject third-party KYC from untrusted provider', async function () {
            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('kyc-tier4-nonce-2'));
            const deadline = currentTime + 3600;

            // Sign with unauthorized signer
            const signature = await signThirdPartyKYC(
                unauthorized,
                user1.address,
                unauthorized.address,
                currentTime,
                nonce,
                deadline
            );

            await expect(
                registration.connect(user1).submitThirdPartyKYCFor(
                    user1.address,
                    unauthorized.address,
                    currentTime,
                    nonce,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'UntrustedKYCProvider');
        });

        it('should reject third-party KYC without Tier 3', async function () {
            // Register user2 with only Tier 1
            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                phoneHash('+1-555-7002'),
                emailHash('kyc-tier4-user2@test.com')
            );

            const currentTime = await time.latest();
            const nonce = keccak256(toUtf8Bytes('kyc-tier4-nonce-3'));
            const deadline = currentTime + 3600;

            const signature = await signThirdPartyKYC(
                kycProvider,
                user2.address,
                kycProvider.address,
                currentTime,
                nonce,
                deadline
            );

            await expect(
                registration.connect(user2).submitThirdPartyKYCFor(
                    user2.address,
                    kycProvider.address,
                    currentTime,
                    nonce,
                    deadline,
                    signature
                )
            ).to.be.revertedWithCustomError(registration, 'PreviousTierRequired');
        });

        it('should verify hasKycTier4 returns false before verification', async function () {
            expect(await registration.hasKycTier4(user1.address)).to.be.false;
        });

        describe('KYC Provider Management', function () {
            it('should add KYC provider', async function () {
                const newProvider = user2.address;

                const tx = await registration.connect(owner).addKYCProvider(newProvider, 'NewProvider');

                await expect(tx).to.emit(registration, 'KYCProviderAdded');
                expect(await registration.trustedKYCProviders(newProvider)).to.be.true;
            });

            it('should remove KYC provider', async function () {
                const tx = await registration.connect(owner).removeKYCProvider(kycProvider.address);

                await expect(tx).to.emit(registration, 'KYCProviderRemoved');
                expect(await registration.trustedKYCProviders(kycProvider.address)).to.be.false;
            });

            it('should reject adding zero address as provider', async function () {
                await expect(
                    registration.connect(owner).addKYCProvider(ZeroAddress, 'Invalid')
                ).to.be.revertedWithCustomError(registration, 'InvalidProvider');
            });

            it('should reject unauthorized provider management', async function () {
                await expect(
                    registration.connect(unauthorized).addKYCProvider(user2.address, 'Hack')
                ).to.be.reverted;

                await expect(
                    registration.connect(unauthorized).removeKYCProvider(kycProvider.address)
                ).to.be.reverted;
            });
        });
    });

    describe('Relay Pattern Tests', function () {
        let trustedKey: any;
        let kycProvider: any;
        let relayVerifyPhone: string;
        let relayEmail: string;

        beforeEach(async function () {
            trustedKey = validator3;
            kycProvider = validator4;
            await registration.connect(owner).setTrustedVerificationKey(trustedKey.address);
            await registration.connect(owner).addKYCProvider(kycProvider.address, 'RelayTestProvider');

            // Generate truly unique identifiers
            const uniqueId = Date.now().toString() + Math.random().toString().slice(2, 8);
            relayVerifyPhone = `+1-RELAY-VERIFY-${uniqueId}`;
            relayEmail = `relay-test-${uniqueId}@test.com`;

            // Register user1 without phone hash (trustless flow sets phone via verification)
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                ethers.ZeroHash,
                emailHash(relayEmail)
            );
        });

        it('should allow relay of ID verification via submitIDVerificationFor', async function () {
            // First complete Tier 1 for user1
            const currentTime = await time.latest();
            const deadline = currentTime + 3600;

            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await registration.getAddress(),
            };

            // Phone verification - use different phone from registration
            const uniqueId = Date.now().toString() + Math.random().toString().slice(2, 8);
            const phoneNonce = keccak256(toUtf8Bytes(`relay-phone-nonce-${uniqueId}`));
            const phoneTypes = {
                PhoneVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'phoneHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const phoneSig = await trustedKey.signTypedData(domain, phoneTypes, {
                user: user1.address,
                phoneHash: phoneHash(relayVerifyPhone),
                timestamp: currentTime,
                nonce: phoneNonce,
                deadline,
            });

            await registration.connect(user1).submitPhoneVerificationFor(
                user1.address,
                phoneHash(relayVerifyPhone),
                currentTime,
                phoneNonce,
                deadline,
                phoneSig
            );

            // Social verification (required for Tier 1 completion)
            const socialHash = keccak256(toUtf8Bytes(`twitter:relayuser-${uniqueId}`));
            const socialNonce = keccak256(toUtf8Bytes(`relay-social-nonce-${uniqueId}`));
            const socialTypes = {
                SocialVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'socialHash', type: 'bytes32' },
                    { name: 'platform', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const socialSig = await trustedKey.signTypedData(domain, socialTypes, {
                user: user1.address,
                socialHash,
                platform: 'twitter',
                timestamp: currentTime,
                nonce: socialNonce,
                deadline,
            });
            await registration.connect(user1).submitSocialVerificationFor(
                user1.address,
                socialHash,
                'twitter',
                currentTime,
                socialNonce,
                deadline,
                socialSig
            );

            // Now relay ID verification (anyone can submit)
            const idHash = keccak256(toUtf8Bytes('PASSPORT:RELAY123:1990-01-01:US'));
            const idNonce = keccak256(toUtf8Bytes('relay-id-nonce'));
            const idTypes = {
                IDVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'idHash', type: 'bytes32' },
                    { name: 'country', type: 'string' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const idSig = await trustedKey.signTypedData(domain, idTypes, {
                user: user1.address,
                idHash,
                country: 'US',
                timestamp: currentTime,
                nonce: idNonce,
                deadline,
            });

            // Submit via RELAY (unauthorized submitter)
            const tx = await registration.connect(unauthorized).submitIDVerificationFor(
                user1.address,
                idHash,
                'US',
                currentTime,
                idNonce,
                deadline,
                idSig
            );

            // Relay should succeed and emit IDVerified
            await expect(tx).to.emit(registration, 'IDVerified');

            // But Tier 2 should NOT be complete yet (need address too)
            expect(await registration.hasKycTier2(user1.address)).to.be.false;
            expect(await registration.kycTier2CompletedAt(user1.address)).to.equal(0);
        });
    });

    describe('SYBIL-H02: Referrer KYC Tier 1 Requirement', function () {
        let tier0Referrer: any;

        beforeEach(async function () {
            const signers = await ethers.getSigners();
            tier0Referrer = signers[10];

            // Register tier0Referrer WITHOUT completing KYC Tier 1
            // (has phone+email from registerUser but NO social verification)
            await registration.connect(validator1).registerUser(
                tier0Referrer.address,
                ZeroAddress,
                phoneHash('+1-555-9999'),
                emailHash('tier0referrer@test.com')
            );

            // Verify tier0Referrer does NOT have KYC Tier 1
            expect(await registration.hasKycTier1(tier0Referrer.address)).to.be.false;

            // Verify the existing referrer DOES have KYC Tier 1
            expect(await registration.hasKycTier1(referrer.address)).to.be.true;
        });

        it('registerUser should revert with Tier 0 referrer', async function () {
            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    tier0Referrer.address,
                    phoneHash('+1-555-8001'),
                    emailHash('newuser-t0ref@test.com')
                )
            ).to.be.revertedWithCustomError(registration, 'ReferrerKycRequired');
        });

        it('registerUser should succeed with Tier 1 referrer', async function () {
            await registration.connect(validator1).registerUser(
                user2.address,
                referrer.address,
                phoneHash('+1-555-8002'),
                emailHash('newuser-t1ref@test.com')
            );

            const reg = await registration.getRegistration(user2.address);
            expect(reg.referrer).to.equal(referrer.address);
        });

        it('registerUser should succeed with no referrer (address(0))', async function () {
            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                phoneHash('+1-555-8003'),
                emailHash('newuser-noref@test.com')
            );

            const reg = await registration.getRegistration(user2.address);
            expect(reg.referrer).to.equal(ZeroAddress);
        });

        it('selfRegisterTrustless should revert with Tier 0 referrer', async function () {
            const emailHashVal = emailHash('trustless-t0ref@test.com');
            const emailTimestamp = await time.latest();
            const emailNonce = keccak256(toUtf8Bytes('t0ref-email-nonce'));
            const emailDeadline = emailTimestamp + 3600;
            const registrationDeadline = emailTimestamp + 3600;

            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then((n: any) => n.chainId);
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: registrationAddress,
            };

            // Create email verification signature
            const emailTypes = {
                EmailVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'emailHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const emailSig = await topLevelVerificationKey.signTypedData(domain, emailTypes, {
                user: user2.address,
                emailHash: emailHashVal,
                timestamp: emailTimestamp,
                nonce: emailNonce,
                deadline: emailDeadline,
            });

            // Create user registration signature
            const regTypes = {
                TrustlessRegistration: [
                    { name: 'user', type: 'address' },
                    { name: 'referrer', type: 'address' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const userSig = await user2.signTypedData(domain, regTypes, {
                user: user2.address,
                referrer: tier0Referrer.address,
                deadline: registrationDeadline,
            });

            await expect(
                registration.connect(user2).selfRegisterTrustless(
                    emailHashVal, emailTimestamp, emailNonce, emailDeadline, emailSig,
                    tier0Referrer.address, registrationDeadline, userSig
                )
            ).to.be.revertedWithCustomError(registration, 'ReferrerKycRequired');
        });

        it('selfRegisterTrustless should succeed with Tier 1 referrer', async function () {
            const emailHashVal = emailHash('trustless-t1ref@test.com');
            const emailTimestamp = await time.latest();
            const emailNonce = keccak256(toUtf8Bytes('t1ref-email-nonce'));
            const emailDeadline = emailTimestamp + 3600;
            const registrationDeadline = emailTimestamp + 3600;

            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then((n: any) => n.chainId);
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: registrationAddress,
            };

            const emailTypes = {
                EmailVerification: [
                    { name: 'user', type: 'address' },
                    { name: 'emailHash', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const emailSig = await topLevelVerificationKey.signTypedData(domain, emailTypes, {
                user: user2.address,
                emailHash: emailHashVal,
                timestamp: emailTimestamp,
                nonce: emailNonce,
                deadline: emailDeadline,
            });

            const regTypes = {
                TrustlessRegistration: [
                    { name: 'user', type: 'address' },
                    { name: 'referrer', type: 'address' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const userSig = await user2.signTypedData(domain, regTypes, {
                user: user2.address,
                referrer: referrer.address,
                deadline: registrationDeadline,
            });

            await registration.connect(user2).selfRegisterTrustless(
                emailHashVal, emailTimestamp, emailNonce, emailDeadline, emailSig,
                referrer.address, registrationDeadline, userSig
            );

            const reg = await registration.getRegistration(user2.address);
            expect(reg.referrer).to.equal(referrer.address);
        });
    });
});
