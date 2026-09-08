/**
 * @file OmniRegistration.test.ts
 * @description Post-split tests for the Base OmniRegistration contract.
 *
 * Post FIX_OMNIREGISTRATION_SPLIT (2026-05-24) + OMNICORE-DECENT:
 *   - Tier-2/3/4 surfaces moved to {OmniRegistrationKYCTiers} — those
 *     tests live in test/attestation/OmniRegistrationKYCTiers.test.ts.
 *   - All Tier-1 submit*Verification* paths now route through the
 *     `OmniAttestationGateway` (mocked here via {MockGatewayForDecent})
 *     and carry a `supersedes` field as part of the EIP-712 envelope.
 *   - {setTrustedVerificationKey} now reverts {LegacyTrustedKeyRetired};
 *     the legacy single-key signing tests are converted to expected-revert.
 *   - {attestKYC} now reverts {LegacyAttestKYCRetired}; same conversion.
 *
 * Tests cover:
 *   - Initialization + role setup
 *   - User registration (referrer + Sybil + daily limit + SYBIL-H02 +
 *     SYBIL-Q-10 deviceHash)
 *   - Tier-1 attestation flow (Phone / Social / Email) with supersedes
 *   - Trustless self-registration (selfRegisterTrustless +
 *     selfRegisterTrustlessFor)
 *   - Bonus markers + admin unregistration + cross-contract sweep into KYCTiers
 *   - Deprecation revert paths for setTrustedVerificationKey + attestKYC
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

// ethers v6: the top-level `ethers` import from hardhat re-exports
// keccak256 + toUtf8Bytes + ZeroAddress on the namespace itself.
const keccak256: (b: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const ZeroAddress: string = ethers.ZeroAddress;

describe('OmniRegistration', function () {
    // Contract instances
    let registration: any;
    let digestLib: any;
    let mockGateway: any;
    let mockVerifier: any;

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

    /**
     * 65-byte placeholder signature accepted by {MockGatewayForDecent}.
     * The mock gateway does not actually verify; tests focus on the
     * chain check + eligibility gate + canonical advance paths owned
     * by {OmniRegistration} itself.
     */
    const MOCK_SIG: string = '0x' + '00'.repeat(65);

    /**
     * Helper: register `user` then complete Tier-1 by calling the
     * Phone + Social submits with the supplied phone hash + social hash.
     * Used by the referrer-setup path in `beforeEach` and by SYBIL-H02
     * tests that need a Tier-1 referrer.
     *
     * @param user        Address to register.
     * @param phoneH      Phone hash to use at registration + submit.
     * @param emailH      Email hash to record at registration.
     * @param socialH     Social hash for the Tier-1 promotion.
     * @param platform    Social platform ('twitter' / 'telegram').
     */
    async function registerAndTier1(
        user: any,
        phoneH: string,
        emailH: string,
        socialH: string,
        platform: string,
    ): Promise<void> {
        await registration.connect(validator1).registerUser(
            user.address,
            ZeroAddress,
            phoneH,
            emailH,
            ethers.ZeroHash,
        );
        // Tier-1 needs BOTH `usedPhoneHashes[reg.phoneHash]` AND a
        // social hash. The phone hash was set + marked used at
        // registerUser time, so submitPhoneVerificationFor would now
        // revert with PhoneAlreadyVerified. Skip it and supply social
        // alone — the contract reads `userSocialHashes[user]` + the
        // already-marked phone hash to complete Tier 1.
        const ts = await time.latest();
        const nonce = keccak256(toUtf8Bytes(
            `tier1-${user.address}-${ts}`,
        ));
        await registration.connect(user).submitSocialVerificationFor(
            user.address, socialH, platform, ethers.ZeroHash,
            ts, nonce, ts + 3600, MOCK_SIG,
        );
    }

    beforeEach(async function () {
        // Get signers
        [owner, validator1, validator2, validator3, validator4, user1, user2, referrer, unauthorized] =
            await ethers.getSigners();

        // Deploy the OMNICORE-DECENT digest library — Base links against
        // it via DELEGATECALL for the supersedes-chain + recordEquivocation
        // helpers.
        const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
        digestLib = await DigestLib.deploy();
        await digestLib.waitForDeployment();
        const libAddr = await digestLib.getAddress();

        // Deploy MockGatewayForDecent + MockBridgeVerifier so submit paths
        // route through the (mocked) attestation gateway. The mock gateway
        // accepts any signature; tests assert OmniRegistration's chain
        // check + state updates, not gateway-side signature recovery.
        const MockGateway = await ethers.getContractFactory('MockGatewayForDecent');
        mockGateway = await MockGateway.deploy();
        await mockGateway.waitForDeployment();

        const MockVerifier = await ethers.getContractFactory('MockBridgeVerifier');
        mockVerifier = await MockVerifier.deploy();
        await mockVerifier.waitForDeployment();
        await mockVerifier.setVerify(true, []);
        await mockGateway.setCommitteeVerifier(await mockVerifier.getAddress());

        // Deploy OmniRegistration as proxy linked to the digest library.
        const OmniRegistration = await ethers.getContractFactory(
            'OmniRegistration',
            { libraries: { OmniRegistrationDigestLib: libAddr } },
        );
        registration = await upgrades.deployProxy(OmniRegistration, [], {
            initializer: 'initialize',
            kind: 'uups',
            constructorArgs: [ethers.ZeroAddress],
            unsafeAllowLinkedLibraries: true,
        });
        await registration.waitForDeployment();

        // Grant roles
        await registration.grantRole(VALIDATOR_ROLE, validator1.address);
        await registration.grantRole(VALIDATOR_ROLE, validator2.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator1.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator2.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator3.address);
        await registration.grantRole(KYC_ATTESTOR_ROLE, validator4.address);

        // Wire the mocked attestation gateway. Replaces the deprecated
        // {setTrustedVerificationKey} path (which now reverts
        // LegacyTrustedKeyRetired post-split).
        await registration.connect(owner).setAttestationGateway(
            await mockGateway.getAddress(),
        );

        // Seed a Tier-1 referrer so SYBIL-H02 register checks pass.
        const referrerPhone = phoneHash('+1-555-0000');
        const referrerEmail = emailHash('referrer@test.com');
        const referrerSocial = keccak256(toUtf8Bytes('twitter:referrer_handle'));
        await registerAndTier1(referrer, referrerPhone, referrerEmail, referrerSocial, 'twitter');
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
            ethers.ZeroHash,
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
            ethers.ZeroHash,
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
            ethers.ZeroHash,
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
            ethers.ZeroHash,
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user1.address,
                    ZeroAddress,
                    phoneHash('+1-555-5555'),
                    emailHash('user5@test.com'),
                    ethers.ZeroHash,
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
            ethers.ZeroHash,
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phone, // Same phone
                    emailHash('user7@test.com'),
                    ethers.ZeroHash,
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
            ethers.ZeroHash,
            );

            await expect(
                registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phoneHash('+1-555-8888'),
                    email, ethers.ZeroHash, // Same email
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
                    ethers.ZeroHash,
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
                    ethers.ZeroHash,
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
                    ethers.ZeroHash,
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
                    ethers.ZeroHash,
                    )
            ).to.be.reverted;
        });
    });

    /**
     * Post-split deprecation: the legacy multi-attestor `attestKYC` path
     * always reverts {LegacyAttestKYCRetired}. Canonical Tier-2/3/4
     * promotions now flow through {OmniRegistrationKYCTiers} (see the
     * dedicated KYCTiers suite). The old per-attestor + threshold +
     * downgrade-protection tests no longer make sense — replaced with
     * a single revert assertion that catches regression if the
     * deprecation is ever rolled back.
     */
    describe('KYC Attestation (deprecated post-split)', function () {
        it('attestKYC always reverts LegacyAttestKYCRetired', async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash('legacy-attest@test.com'),
                ethers.ZeroHash,
            );
            for (const v of [validator1, validator2, validator3, validator4]) {
                await expect(
                    registration.connect(v).attestKYC(user1.address, 2),
                ).to.be.revertedWithCustomError(
                    registration, 'LegacyAttestKYCRetired',
                );
            }
        });

        it('attestKYC reverts for every tier value, including the previously-invalid ones', async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash('legacy-attest-tiers@test.com'),
                ethers.ZeroHash,
            );
            for (const tier of [0, 1, 2, 3, 4, 5]) {
                await expect(
                    registration.connect(validator2).attestKYC(user1.address, tier),
                ).to.be.revertedWithCustomError(
                    registration, 'LegacyAttestKYCRetired',
                );
            }
        });
    });

    describe('Bonus Eligibility', function () {
        beforeEach(async function () {
            await registration.connect(validator1).registerUser(
                user1.address,
                referrer.address,
                phoneHash('+1-555-4000'),
                emailHash('bonus-user@test.com')
            ,
                ethers.ZeroHash);
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
        // Mock-gateway happy-path signature. Verification is delegated to
        // {OmniAttestationGateway} (mocked here via {MockGatewayForDecent})
        // which accepts any signature; the tests below assert
        // OmniRegistration's chain check + state updates.
        const mockSig: string = '0x' + '00'.repeat(65);

        /**
         * Generate a unique nonce.
         */
        function generateNonce(): string {
            return keccak256(toUtf8Bytes(`nonce-${Date.now()}-${Math.random()}`));
        }

        /**
         * Generate social hash for testing.
         */
        function socialHash(platform: string, handle: string): string {
            return keccak256(toUtf8Bytes(`${platform}:${handle}`));
        }

        /**
         * Build the EIP-712 trustless registration user signature. The
         * envelope shape mirrors the on-chain `_selfRegisterTrustlessInternal`
         * recomputation (SYBIL-Q-10 included `deviceHash` in the tuple).
         *
         * @param signer       Account signing the registration intent.
         * @param user         Subject address (must equal recoverable signer).
         * @param referrerAddr Referrer (or ZeroAddress).
         * @param deadline     Registration request deadline.
         * @param deviceHash   SYBIL-Q-10 device fingerprint (or ZeroHash).
         */
        async function createRegistrationSignature(
            signer: any,
            user: string,
            referrerAddr: string,
            deadline: number,
            deviceHash: string = ethers.ZeroHash,
        ): Promise<string> {
            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then(
                (n: any) => n.chainId,
            );

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
                    { name: 'deviceHash', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = {
                user: user,
                referrer: referrerAddr,
                deviceHash: deviceHash,
                deadline: deadline,
            };

            return await signer.signTypedData(domain, types, value);
        }

        beforeEach(async function () {
            // No trustedVerificationKey wiring — the post-split
            // attestation gateway is the single verification surface
            // (already wired in the outer beforeEach via
            // {setAttestationGateway}). The legacy single-key path
            // reverts {LegacyTrustedKeyRetired}.

            // Register user1 without phone hash so trustless phone
            // verification can be tested.
            await registration.connect(validator1).registerUser(
                user1.address,
                ZeroAddress,
                ethers.ZeroHash,
                emailHash('trustless-user@test.com'),
                ethers.ZeroHash,
            );
        });

        describe('setTrustedVerificationKey (deprecated post-split)', function () {
            it('always reverts LegacyTrustedKeyRetired', async function () {
                await expect(
                    registration.connect(owner)
                        .setTrustedVerificationKey(user2.address),
                ).to.be.revertedWithCustomError(
                    registration, 'LegacyTrustedKeyRetired',
                );
            });

            it('still rejects unauthorized callers (access control runs first)', async function () {
                await expect(
                    registration.connect(unauthorized)
                        .setTrustedVerificationKey(user2.address),
                ).to.be.reverted;
            });
        });

        describe('submitPhoneVerification', function () {
            // Post-split: signature validity / nonce reuse / deadline
            // expiration are all handled by the (mocked) attestation
            // gateway. The Base-side concerns asserted below are:
            //   - registered-user gate
            //   - phone-already-verified gate
            //   - phone-hash-already-used gate
            //   - supersedes chain check
            //   - state updates + event emission

            it('should verify phone with valid signature', async function () {
                // Register a new user without phone verified yet
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash, // No phone hash
                    emailHash('phone-test@test.com'),
                    ethers.ZeroHash,
                );

                const newPhoneHash = phoneHash('+1-555-7001');
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600; // 1 hour from now

                const tx = await registration.connect(user2).submitPhoneVerificationFor(
                    user2.address,
                    newPhoneHash,
                    ethers.ZeroHash, // first attestation → supersedes = 0
                    timestamp,
                    nonce,
                    deadline,
                    mockSig,
                );

                await expect(tx)
                    .to.emit(registration, 'PhoneVerified')
                    .withArgs(user2.address, newPhoneHash, timestamp);
            });

            it('reverts NotRegistered for an unregistered subject', async function () {
                const ghost = ethers.Wallet.createRandom();
                const timestamp = await time.latest();
                await expect(
                    registration.connect(user1).submitPhoneVerificationFor(
                        ghost.address,
                        phoneHash('+1-555-ghost'),
                        ethers.ZeroHash,
                        timestamp,
                        generateNonce(),
                        timestamp + 3600,
                        mockSig,
                    ),
                ).to.be.revertedWithCustomError(registration, 'NotRegistered');
            });

            it('reverts PhoneAlreadyVerified when a phone is already attested', async function () {
                // Register user2 + complete phone attestation once.
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('phone-already@test.com'),
                    ethers.ZeroHash,
                );
                const ts = await time.latest();
                await registration.connect(user2).submitPhoneVerificationFor(
                    user2.address,
                    phoneHash('+1-555-already'),
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );

                // Second attestation for the SAME user is blocked because
                // `reg.phoneHash` is non-zero (M-03 lockout).
                await expect(
                    registration.connect(user2).submitPhoneVerificationFor(
                        user2.address,
                        phoneHash('+1-555-different'),
                        ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'PhoneAlreadyVerified',
                );
            });

            it('reverts PhoneAlreadyUsed when another user already claimed the hash', async function () {
                const sharedHash = phoneHash('+1-555-shared');

                // user1 attests the shared hash first.
                const ts1 = await time.latest();
                await registration.connect(user1).submitPhoneVerificationFor(
                    user1.address,
                    sharedHash,
                    ethers.ZeroHash, ts1, generateNonce(), ts1 + 3600, mockSig,
                );

                // Register user2 with NO phone hash.
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('phone-shared@test.com'),
                    ethers.ZeroHash,
                );
                const ts2 = await time.latest();
                await expect(
                    registration.connect(user2).submitPhoneVerificationFor(
                        user2.address,
                        sharedHash,
                        ethers.ZeroHash, ts2, generateNonce(), ts2 + 3600, mockSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'PhoneAlreadyUsed',
                );
            });

            it('rejects wrong supersedes when chain is established', async function () {
                // Phone attestations land at most once per user (PhoneAlreadyVerified
                // blocks the second), so the supersedes-chain check fires
                // BEFORE that check only on the FIRST submission. Exercise
                // it by submitting with a non-zero supersedes upfront —
                // the chain head is `bytes32(0)` so the mismatch trips
                // InvalidSupersedes.
                const ts = await time.latest();
                await expect(
                    registration.connect(user1).submitPhoneVerificationFor(
                        user1.address,
                        phoneHash('+1-555-supersedes'),
                        keccak256(toUtf8Bytes('fake-prior-digest')),
                        ts, generateNonce(), ts + 3600, mockSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'InvalidSupersedes',
                );
            });

            // Investigated but intentionally NOT carried forward post-split:
            //   * `reject expired proof` — gateway owns deadline checks.
            //   * `reject reused nonce` — gateway owns the nonce map.
            //   * `reject invalid signature` — gateway owns recovery +
            //     committee-verifier validity.
            //   * `reject if trusted verification key not set` — legacy
            //     path retired (`LegacyTrustedKeyRetired`), gateway is the
            //     single trust surface.
            it.skip('expired proof / reused nonce / invalid signature / unset key — owned by gateway', function () {
                // Covered in OmniAttestationGateway tests.
            });
        });

        describe('submitPhoneVerification — gateway-owned cases (skipped, covered in gateway suite)', function () {
            it.skip('reject expired proof — owned by OmniAttestationGateway', function () { /* moved */ });
            it.skip('reject reused nonce — owned by OmniAttestationGateway', function () { /* moved */ });
            it.skip('reject invalid signature — owned by OmniAttestationGateway', function () { /* moved */ });
            it.skip('reject if trusted verification key not set — path retired (LegacyTrustedKeyRetired)', function () { /* moved */ });
            it.skip('phone hash already used (legacy variant) — covered above with mocked gateway', function () { /* moved */ });
        });

        /* ZOMBIE BLOCK — preserved purely so the closing `}` brace
         * pairing in the original 3000-line file stays balanced
         * during the migration. Body is reduced to a no-op describe
         * that nests one no-op `it.skip` so the surrounding parser
         * doesn't trip on the empty function body. */
        describe.skip('zombie-block — original legacy phone tests (deleted post-split)', function () { /* body deleted: referenced removed verificationKey + createPhoneVerificationSignature helpers; gateway-owned cases are skip-stubbed above */ });

        describe('submitSocialVerification', function () {
            it('should verify social with valid signature', async function () {
                const socialHashVal = socialHash('twitter', 'user1handle');
                const platform = 'twitter';
                const timestamp = await time.latest();
                const nonce = generateNonce();
                const deadline = timestamp + 3600;

                const tx = await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
                    socialHashVal,
                    platform,
                    ethers.ZeroHash, // first attestation → supersedes = 0
                    timestamp,
                    nonce,
                    deadline,
                    mockSig,
                );

                await expect(tx)
                    .to.emit(registration, 'SocialVerified')
                    .withArgs(user1.address, socialHashVal, platform, timestamp);

                expect(await registration.userSocialHashes(user1.address))
                    .to.equal(socialHashVal);
            });

            it('reverts NotRegistered for an unregistered subject', async function () {
                const ghost = ethers.Wallet.createRandom();
                const ts = await time.latest();
                await expect(
                    registration.connect(user1).submitSocialVerificationFor(
                        ghost.address,
                        socialHash('twitter', 'ghost-handle'),
                        'twitter',
                        ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                    ),
                ).to.be.revertedWithCustomError(registration, 'NotRegistered');
            });

            it('reverts SocialAlreadyVerified on second attestation', async function () {
                const ts = await time.latest();
                await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
                    socialHash('twitter', 'first-handle'),
                    'twitter',
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );
                await expect(
                    registration.connect(user1).submitSocialVerificationFor(
                        user1.address,
                        socialHash('twitter', 'second-handle'),
                        'twitter',
                        ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'SocialAlreadyVerified',
                );
            });

            it('reverts SocialAlreadyUsed when another user claimed the hash', async function () {
                const sharedSocial = socialHash('twitter', 'shared-handle');
                const ts = await time.latest();
                await registration.connect(user1).submitSocialVerificationFor(
                    user1.address, sharedSocial, 'twitter',
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );

                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    phoneHash('+1-555-7011'),
                    emailHash('dup-social@test.com'),
                    ethers.ZeroHash,
                );
                const ts2 = await time.latest();
                await expect(
                    registration.connect(user2).submitSocialVerificationFor(
                        user2.address, sharedSocial, 'twitter',
                        ethers.ZeroHash, ts2, generateNonce(), ts2 + 3600, mockSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'SocialAlreadyUsed',
                );
            });

            it('should work with telegram platform', async function () {
                const socialHashVal = socialHash('telegram', 'telegram-handle');
                const platform = 'telegram';
                const ts = await time.latest();

                const tx = await registration.connect(user1).submitSocialVerificationFor(
                    user1.address, socialHashVal, platform,
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );

                await expect(tx)
                    .to.emit(registration, 'SocialVerified')
                    .withArgs(user1.address, socialHashVal, platform, ts);
            });

            // See gateway suite for: expired-proof, reused-nonce, invalid-
            // signature — all owned by OmniAttestationGateway post-split.
            it.skip('reject expired proof — owned by OmniAttestationGateway', function () { /* moved */ });
            it.skip('reject reused nonce — owned by OmniAttestationGateway', function () { /* moved */ });
            it.skip('reject invalid signature — owned by OmniAttestationGateway', function () { /* moved */ });
        });


        describe('hasKycTier1', function () {
            it('should return false before verifications', async function () {
                // Register a fresh user
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash,
                    emailHash('tier1-fresh@test.com'),
                    ethers.ZeroHash,
                );
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });

            it('should return false after phone verification only', async function () {
                // user1 (registered in beforeEach without phone) attests phone only.
                const ts = await time.latest();
                await registration.connect(user1).submitPhoneVerificationFor(
                    user1.address,
                    phoneHash('+1-555-tier1-phone-only'),
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );
                expect(await registration.hasKycTier1(user1.address)).to.be.false;
            });

            it('should return false after social verification only', async function () {
                // Fresh user2 has no phone marked used (registered with ZeroHash phone).
                await registration.connect(validator1).registerUser(
                    user2.address,
                    ZeroAddress,
                    ethers.ZeroHash, // no phone
                    emailHash('tier1-social-only@test.com'),
                    ethers.ZeroHash,
                );
                const ts = await time.latest();
                await registration.connect(user2).submitSocialVerificationFor(
                    user2.address,
                    socialHash('twitter', 'tier1-social-only'),
                    'twitter',
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });

            it('should return true after both phone + social verification', async function () {
                // user1 needs phone + social.
                const ts = await time.latest();
                await registration.connect(user1).submitPhoneVerificationFor(
                    user1.address,
                    phoneHash('+1-555-tier1-both'),
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );
                await registration.connect(user1).submitSocialVerificationFor(
                    user1.address,
                    socialHash('twitter', 'tier1-both'),
                    'twitter',
                    ethers.ZeroHash, ts, generateNonce(), ts + 3600, mockSig,
                );
                expect(await registration.hasKycTier1(user1.address)).to.be.true;
            });

            it('should return false for unregistered user', async function () {
                expect(await registration.hasKycTier1(user2.address)).to.be.false;
            });
        });

        describe('selfRegisterTrustless', function () {
            // Email verification routes through the (mocked) attestation
            // gateway. The user's TrustlessRegistration signature is
            // recovered directly on-chain via ecrecover — that helper
            // (`createRegistrationSignature`) lives at the top of this
            // describe block.

            it('should register with valid email proof and user signature', async function () {
                const fresh = ethers.Wallet.createRandom();
                const emailHashVal = emailHash(`srt-${fresh.address}@test.com`);
                const ts = await time.latest();
                const userSig = await createRegistrationSignature(
                    fresh, fresh.address, ZeroAddress, ts + 3600,
                );

                await expect(
                    registration.connect(user1).selfRegisterTrustlessFor(
                        fresh.address,
                        emailHashVal,
                        ts,                  // emailTimestamp
                        generateNonce(),     // emailNonce
                        ts + 3600,           // emailDeadline
                        mockSig,             // emailSignature (gateway-checked)
                        ZeroAddress,         // referrer
                        ethers.ZeroHash,     // deviceHash
                        ts + 3600,           // registrationDeadline
                        userSig,
                    ),
                ).to.emit(registration, 'UserRegisteredTrustless');
                expect(await registration.isRegistered(fresh.address)).to.be.true;
            });

            it('reverts AlreadyRegistered when called twice', async function () {
                const fresh = ethers.Wallet.createRandom();
                const emailHashVal = emailHash(`srt-${fresh.address}@test.com`);
                const ts = await time.latest();
                const userSig = await createRegistrationSignature(
                    fresh, fresh.address, ZeroAddress, ts + 3600,
                );
                await registration.connect(user1).selfRegisterTrustlessFor(
                    fresh.address,
                    emailHashVal, ts, generateNonce(), ts + 3600, mockSig,
                    ZeroAddress, ethers.ZeroHash, ts + 3600, userSig,
                );
                await expect(
                    registration.connect(user1).selfRegisterTrustlessFor(
                        fresh.address,
                        emailHash(`srt-other-${fresh.address}@test.com`),
                        ts, generateNonce(), ts + 3600, mockSig,
                        ZeroAddress, ethers.ZeroHash, ts + 3600, userSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'AlreadyRegistered',
                );
            });

            it('reverts EmailAlreadyUsed when another user claimed the email', async function () {
                const u1Wallet = ethers.Wallet.createRandom();
                const u2Wallet = ethers.Wallet.createRandom();
                const sharedEmail = emailHash('srt-shared-email@test.com');
                const ts = await time.latest();

                const u1Sig = await createRegistrationSignature(
                    u1Wallet, u1Wallet.address, ZeroAddress, ts + 3600,
                );
                await registration.connect(user1).selfRegisterTrustlessFor(
                    u1Wallet.address,
                    sharedEmail, ts, generateNonce(), ts + 3600, mockSig,
                    ZeroAddress, ethers.ZeroHash, ts + 3600, u1Sig,
                );

                const u2Sig = await createRegistrationSignature(
                    u2Wallet, u2Wallet.address, ZeroAddress, ts + 3600,
                );
                await expect(
                    registration.connect(user1).selfRegisterTrustlessFor(
                        u2Wallet.address,
                        sharedEmail, ts, generateNonce(), ts + 3600, mockSig,
                        ZeroAddress, ethers.ZeroHash, ts + 3600, u2Sig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'EmailAlreadyUsed',
                );
            });

            it('reverts InvalidUserSignature when the user signature is wrong', async function () {
                // Hardhat ships 20 signers — out-of-band signers are
                // off-chain `ethers.Wallet` instances. Random wallets
                // can sign EIP-712 (Wallet.signTypedData) without any
                // on-chain balance; the relay path
                // (`selfRegisterTrustlessFor`) carries the tx.
                const fresh = ethers.Wallet.createRandom();
                const wrongSigner = ethers.Wallet.createRandom();
                const ts = await time.latest();
                const wrongSig = await createRegistrationSignature(
                    wrongSigner, fresh.address, ZeroAddress, ts + 3600,
                );
                await expect(
                    registration.connect(user1).selfRegisterTrustlessFor(
                        fresh.address,
                        emailHash(`srt-wrong-${fresh.address}@test.com`),
                        ts, generateNonce(), ts + 3600, mockSig,
                        ZeroAddress, ethers.ZeroHash, ts + 3600, wrongSig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'InvalidUserSignature',
                );
            });

            it('reverts SelfReferralNotAllowed', async function () {
                const fresh = ethers.Wallet.createRandom();
                const ts = await time.latest();
                // SelfReferralNotAllowed fires only when the referrer is
                // NOT address(0) AND equals user. Sign with referrer=self.
                const sig = await createRegistrationSignature(
                    fresh, fresh.address, fresh.address, ts + 3600,
                );
                await expect(
                    registration.connect(user1).selfRegisterTrustlessFor(
                        fresh.address,
                        emailHash(`srt-self-${fresh.address}@test.com`),
                        ts, generateNonce(), ts + 3600, mockSig,
                        fresh.address,        // referrer = user
                        ethers.ZeroHash,
                        ts + 3600,
                        sig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'SelfReferralNotAllowed',
                );
            });

            it('reverts InvalidReferrer for unregistered referrer', async function () {
                const fresh = ethers.Wallet.createRandom();
                const ghost = ethers.Wallet.createRandom();
                const ts = await time.latest();
                const sig = await createRegistrationSignature(
                    fresh, fresh.address, ghost.address, ts + 3600,
                );
                await expect(
                    registration.connect(user1).selfRegisterTrustlessFor(
                        fresh.address,
                        emailHash(`srt-ghost-${fresh.address}@test.com`),
                        ts, generateNonce(), ts + 3600, mockSig,
                        ghost.address,        // not registered
                        ethers.ZeroHash,
                        ts + 3600,
                        sig,
                    ),
                ).to.be.revertedWithCustomError(
                    registration, 'InvalidReferrer',
                );
            });

            it('relay path: selfRegisterTrustlessFor lets any caller relay', async function () {
                const fresh = ethers.Wallet.createRandom();
                const relayer = unauthorized; // any funded signer works
                const ts = await time.latest();
                const sig = await createRegistrationSignature(
                    fresh, fresh.address, ZeroAddress, ts + 3600,
                );
                await expect(
                    registration.connect(relayer).selfRegisterTrustlessFor(
                        fresh.address,
                        emailHash(`srt-relay-${fresh.address}@test.com`),
                        ts, generateNonce(), ts + 3600, mockSig,
                        ZeroAddress, ethers.ZeroHash, ts + 3600, sig,
                    ),
                ).to.emit(registration, 'UserRegisteredTrustless');
                expect(await registration.isRegistered(fresh.address)).to.be.true;
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
            ,
                ethers.ZeroHash);
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
            , ethers.ZeroHash);

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
            ,
                ethers.ZeroHash);

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
            ,
                ethers.ZeroHash);

            // Unregister user1 first
            await registration.connect(owner).adminUnregister(user1.address);

            // Batch should still work (skips user1)
            await registration.connect(owner).adminUnregisterBatch([user1.address, user2.address]);

            expect(await registration.isRegistered(user2.address)).to.be.false;
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //          KYC TIER 2/3/4 + Relay Pattern Tests — fully relocated
    // ═══════════════════════════════════════════════════════════════════════
    //
    // The 30 tests that previously inhabited this region (KYC Tier 2 ID
    // Verification + KYC Tier 3 Persona/AML/Accredited Investor + KYC
    // Tier 4 Third-Party KYC + KYC Provider Management + the generic
    // relay-pattern test) have been relocated wholesale to:
    //
    //   test/attestation/OmniRegistrationKYCTiers.test.ts  (29 tests)
    //
    // …where they exercise the post-split OmniRegistrationKYCTiers proxy
    // (which now owns those surfaces) rather than the Base contract (which
    // no longer carries them). Coverage of the cross-contract callback,
    // supersedes-chain, recordEquivocation typehash gating, and audit-
    // remediation regressions continues to live in the sibling files:
    //
    //   test/attestation/OmniRegistrationSplit.test.ts        (13 tests)
    //   test/attestation/OmniRegistrationSplitAudit.test.ts   (23 tests)
    //
    // The original ~1900 lines of skipped legacy bodies are preserved in
    // git history (see prior commits on this branch); the in-place skip
    // blocks were removed in this commit to drop the dead-code surface.


    describe('SYBIL-H02: Referrer KYC Tier 1 Requirement', function () {
        let tier0Referrer: any;

        // Local helper — the outer `createRegistrationSignature` lives in
        // a sibling describe block and isn't in scope here.
        async function signRegistration(
            signer: any,
            user: string,
            referrerAddr: string,
            deadline: number,
            deviceHash: string = ethers.ZeroHash,
        ): Promise<string> {
            const registrationAddress = await registration.getAddress();
            const chainId = await ethers.provider.getNetwork().then(
                (n: any) => n.chainId,
            );
            return await signer.signTypedData(
                {
                    name: 'OmniRegistration',
                    version: '1',
                    chainId: chainId,
                    verifyingContract: registrationAddress,
                },
                {
                    TrustlessRegistration: [
                        { name: 'user', type: 'address' },
                        { name: 'referrer', type: 'address' },
                        { name: 'deviceHash', type: 'bytes32' },
                        { name: 'deadline', type: 'uint256' },
                    ],
                },
                {
                    user: user,
                    referrer: referrerAddr,
                    deviceHash: deviceHash,
                    deadline: deadline,
                },
            );
        }

        const mockSig: string = '0x' + '00'.repeat(65);

        beforeEach(async function () {
            const signers = await ethers.getSigners();
            tier0Referrer = signers[10];

            // Register tier0Referrer WITHOUT completing KYC Tier 1
            // (has phone+email from registerUser but NO social verification)
            await registration.connect(validator1).registerUser(
                tier0Referrer.address,
                ZeroAddress,
                phoneHash('+1-555-9999'),
                emailHash('tier0referrer@test.com'),
                ethers.ZeroHash,
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
                    emailHash('newuser-t0ref@test.com'),
                    ethers.ZeroHash,
                ),
            ).to.be.revertedWithCustomError(registration, 'ReferrerKycRequired');
        });

        it('registerUser should succeed with Tier 1 referrer', async function () {
            await registration.connect(validator1).registerUser(
                user2.address,
                referrer.address,
                phoneHash('+1-555-8002'),
                emailHash('newuser-t1ref@test.com'),
                ethers.ZeroHash,
            );

            const reg = await registration.getRegistration(user2.address);
            expect(reg.referrer).to.equal(referrer.address);
        });

        it('registerUser should succeed with no referrer (address(0))', async function () {
            await registration.connect(validator1).registerUser(
                user2.address,
                ZeroAddress,
                phoneHash('+1-555-8003'),
                emailHash('newuser-noref@test.com'),
                ethers.ZeroHash,
            );

            const reg = await registration.getRegistration(user2.address);
            expect(reg.referrer).to.equal(ZeroAddress);
        });

        it('selfRegisterTrustless should revert with Tier 0 referrer', async function () {
            // Use a random Wallet so we don't collide with already-
            // registered hardhat signers (referrer / user1 / etc).
            const fresh = ethers.Wallet.createRandom();
            const ts = await time.latest();
            const emailHashVal = emailHash(`srt-t0ref-${fresh.address}@test.com`);
            const userSig = await signRegistration(
                fresh, fresh.address, tier0Referrer.address, ts + 3600,
            );

            const nonce = keccak256(toUtf8Bytes(`srt-t0ref-nonce-${fresh.address}`));
            await expect(
                registration.connect(user1).selfRegisterTrustlessFor(
                    fresh.address,
                    emailHashVal, ts, nonce, ts + 3600, mockSig,
                    tier0Referrer.address, ethers.ZeroHash, ts + 3600, userSig,
                ),
            ).to.be.revertedWithCustomError(registration, 'ReferrerKycRequired');
        });

        it('selfRegisterTrustless should succeed with Tier 1 referrer', async function () {
            const fresh = ethers.Wallet.createRandom();
            const ts = await time.latest();
            const emailHashVal = emailHash(`srt-t1ref-${fresh.address}@test.com`);
            const userSig = await signRegistration(
                fresh, fresh.address, referrer.address, ts + 3600,
            );

            const nonce = keccak256(toUtf8Bytes(`srt-t1ref-nonce-${fresh.address}`));
            await registration.connect(user1).selfRegisterTrustlessFor(
                fresh.address,
                emailHashVal, ts, nonce, ts + 3600, mockSig,
                referrer.address, ethers.ZeroHash, ts + 3600, userSig,
            );

            const reg = await registration.getRegistration(fresh.address);
            expect(reg.referrer).to.equal(referrer.address);
        });
    });

});
