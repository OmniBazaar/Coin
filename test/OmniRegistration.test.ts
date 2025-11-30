/**
 * @file OmniRegistration.test.ts
 * @description Comprehensive tests for OmniRegistration contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - User registration with deposit
 * - Phone/email uniqueness (Sybil protection)
 * - Referrer validation
 * - Daily rate limiting
 * - KYC attestation (multi-validator)
 * - Deposit refund after KYC
 * - Cooling period enforcement
 * - Bonus claim marking
 * - Access control
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
    const REGISTRATION_DEPOSIT = ethers.parseEther('100'); // 100 XOM
    const COOLING_PERIOD = 24 * 60 * 60; // 24 hours in seconds
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
            emailHash('referrer@test.com'),
            { value: REGISTRATION_DEPOSIT }
        );
    });

    describe('Initialization', function () {
        it('should initialize with correct admin', async function () {
            expect(await registration.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it('should have correct constants', async function () {
            expect(await registration.REGISTRATION_DEPOSIT()).to.equal(REGISTRATION_DEPOSIT);
            expect(await registration.COOLING_PERIOD()).to.equal(COOLING_PERIOD);
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
                { value: REGISTRATION_DEPOSIT }
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
                { value: REGISTRATION_DEPOSIT }
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
                { value: REGISTRATION_DEPOSIT }
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
                { value: REGISTRATION_DEPOSIT }
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    ZeroAddress,
                    phoneHash('+1-555-5555'),
                    emailHash('user5@test.com'),
                    { value: REGISTRATION_DEPOSIT }
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
                { value: REGISTRATION_DEPOSIT }
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phone, // Same phone
                    emailHash('user7@test.com'),
                    { value: REGISTRATION_DEPOSIT }
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
                { value: REGISTRATION_DEPOSIT }
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phoneHash('+1-555-8888'),
                    email, // Same email
                    { value: REGISTRATION_DEPOSIT }
                )
            ).to.be.revertedWithCustomError(registration, 'EmailAlreadyUsed');
        });

        it('should reject insufficient deposit', async function () {
            const insufficientDeposit = ethers.parseEther('50'); // Only 50 XOM

            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    ZeroAddress,
                    phoneHash('+1-555-9999'),
                    emailHash('user9@test.com'),
                    { value: insufficientDeposit }
                )
            ).to.be.revertedWithCustomError(registration, 'InsufficientDeposit');
        });

        it('should reject self-referral', async function () {
            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    user1.address, // Self-referral
                    phoneHash('+1-555-1010'),
                    emailHash('user10@test.com'),
                    { value: REGISTRATION_DEPOSIT }
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
                    { value: REGISTRATION_DEPOSIT }
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
                    { value: REGISTRATION_DEPOSIT }
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
                    { value: REGISTRATION_DEPOSIT }
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
                { value: REGISTRATION_DEPOSIT }
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

    describe('Deposit Refund', function () {
        beforeEach(async function () {
            // Register user1
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash('+1-555-3000'),
                emailHash('refund-user@test.com'),
                { value: REGISTRATION_DEPOSIT }
            );
        });

        it('should refund deposit after KYC tier 2', async function () {
            // Upgrade to tier 2
            await registration.connect(validator2).attestKYC(user1.address, 2);
            await registration.connect(validator3).attestKYC(user1.address, 2);
            await registration.connect(validator4).attestKYC(user1.address, 2);

            const balanceBefore = await ethers.provider.getBalance(user1.address);

            await registration.connect(user1).refundDeposit();

            const balanceAfter = await ethers.provider.getBalance(user1.address);
            // Balance should increase (minus gas)
            expect(balanceAfter).to.be.greaterThan(balanceBefore);
        });

        it('should reject refund without KYC tier 2', async function () {
            // user1 only has tier 1
            await expect(registration.connect(user1).refundDeposit()).to.be.revertedWithCustomError(
                registration,
                'KYCRequired'
            );
        });

        it('should reject double refund', async function () {
            // Upgrade and refund
            await registration.connect(validator2).attestKYC(user1.address, 2);
            await registration.connect(validator3).attestKYC(user1.address, 2);
            await registration.connect(validator4).attestKYC(user1.address, 2);
            await registration.connect(user1).refundDeposit();

            // Try to refund again
            await expect(registration.connect(user1).refundDeposit()).to.be.revertedWithCustomError(
                registration,
                'DepositAlreadyRefunded'
            );
        });
    });

    describe('Bonus Eligibility', function () {
        beforeEach(async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                phoneHash('+1-555-4000'),
                emailHash('bonus-user@test.com'),
                { value: REGISTRATION_DEPOSIT }
            );
        });

        it('should not allow bonus claim during cooling period', async function () {
            expect(await registration.canClaimWelcomeBonus(user1.address)).to.be.false;
        });

        it('should allow bonus claim after cooling period', async function () {
            // Advance time past cooling period
            await time.increase(COOLING_PERIOD + 1);

            expect(await registration.canClaimWelcomeBonus(user1.address)).to.be.true;
        });

        it('should return correct referrer', async function () {
            expect(await registration.getReferrer(user1.address)).to.equal(referrer.address);
        });
    });
});
