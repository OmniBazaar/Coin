/**
 * OmniRegistrationKYCTiers — relocated Tier-2/3/4 coverage.
 *
 * Migrated from the pre-split Coin/test/OmniRegistration.test.ts where
 * these 30 tests originally ran against the monolithic OmniRegistration
 * contract. Post-split (FIX_OMNIREGISTRATION_SPLIT 2026-05-24) the
 * Tier-2/3/4 attestation surface lives exclusively on the new
 * OmniRegistrationKYCTiers proxy; the legacy locations are skipped with
 * relocation notes pointing here.
 *
 * Covered:
 *   - KYC Tier 2 (ID / Address / Selfie + tier completion + bumpKycTier callback)
 *   - KYC Tier 3 (Persona + AML + Accredited Investor + tier completion)
 *   - KYC Tier 4 (Third-Party KYC via trusted provider sig)
 *   - KYC Provider Management (admin add / remove + access control)
 *   - Relay-path positive — anyone can call submit*VerificationFor.
 *
 * Cross-contract / supersedes-chain / recordEquivocation / audit-
 * remediation coverage stays in:
 *   - test/attestation/OmniRegistrationSplit.test.ts
 *   - test/attestation/OmniRegistrationSplitAudit.test.ts
 *
 * @module test/attestation/OmniRegistrationKYCTiers
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

const keccak256: (b: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const ZeroAddress: string = ethers.ZeroAddress;

describe('OmniRegistrationKYCTiers — Tier-2/3/4 surface', function () {
    let registration: any;       // Base
    let kycTiers: any;           // KYCTiers proxy
    let mockGateway: any;
    let mockVerifier: any;
    let lib: any;

    let owner: any;
    let admin: any;
    let user1: any;
    let user2: any;
    let provider1: any;
    let otherAccount: any;

    const VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
    const KYCTIERS_ROLE = keccak256(toUtf8Bytes('KYCTIERS_ROLE'));
    /**
     * 65-byte placeholder accepted by {MockGatewayForDecent}.
     * The mock gateway accepts any signature; tests assert KYCTiers'
     * own state transitions + cross-contract callbacks into Base.
     */
    const MOCK_SIG: string = '0x' + '00'.repeat(65);

    /**
     * Build a unique nonce derived from the caller-supplied tag.
     *
     * @param tag - Short string used to disambiguate this call.
     * @returns Hex-encoded 32-byte nonce.
     */
    function generateNonce(tag: string): string {
        return keccak256(toUtf8Bytes(`kyctiers-test-${tag}-${Date.now()}`));
    }

    /**
     * Hash a payload string for use as an ID / address hash.
     *
     * @param s - Source string (e.g. passport number, address line).
     * @returns Keccak256 hex string.
     */
    function h(s: string): string {
        return keccak256(toUtf8Bytes(s));
    }

    /**
     * Register `addr` on Base + bump them to Tier 1 manually via the
     * KYCTIERS_ROLE callback. KYCTiers's Tier-2 submit gate reads
     * `baseRegistration.kycTier1CompletedAt(user) != 0` so the Tier-1
     * timestamp also has to be set — done here through the canonical
     * submitSocialVerificationFor path with the mock gateway accepting
     * any signature.
     *
     * @param addr Subject address.
     */
    async function registerAndTier1(addr: string): Promise<void> {
        await registration.connect(admin).registerUser(
            addr,
            ZeroAddress,
            keccak256(toUtf8Bytes(`phone:${addr}`)),
            keccak256(toUtf8Bytes(`email:${addr}`)),
            ethers.ZeroHash,
        );
        // Tier-1 needs both `usedPhoneHashes[reg.phoneHash]` (already
        // marked true at registerUser time) AND a social hash. Submit
        // social through the mocked attestation path.
        const ts = await time.latest();
        await registration.connect(admin).submitSocialVerificationFor(
            addr,
            keccak256(toUtf8Bytes(`twitter:${addr}`)),
            'twitter',
            ethers.ZeroHash,
            ts,
            generateNonce(`tier1-${addr}`),
            ts + 3600,
            MOCK_SIG,
        );
    }

    /**
     * Drive a user to Tier-2 completion via the KYCTiers submit path —
     * ID + Address + Selfie all attest, triggering the cross-contract
     * `bumpKycTier(user, 2)` callback into Base.
     *
     * @param addr Subject address.
     */
    async function tier2Complete(addr: string): Promise<void> {
        const ts = await time.latest();
        await kycTiers.connect(admin).submitIDVerificationFor(
            addr, h(`passport:${addr}`), 'US',
            ethers.ZeroHash, ts, generateNonce(`id-${addr}`),
            ts + 3600, MOCK_SIG,
        );
        await kycTiers.connect(admin).submitAddressVerificationFor(
            addr, h(`address:${addr}`), 'US',
            keccak256(toUtf8Bytes('utility_bill')),
            ethers.ZeroHash, ts, generateNonce(`addr-${addr}`),
            ts + 3600, MOCK_SIG,
        );
        await kycTiers.connect(admin).submitSelfieVerificationFor(
            addr, h(`selfie:${addr}`), 95,
            ethers.ZeroHash, ts, generateNonce(`selfie-${addr}`),
            ts + 3600, MOCK_SIG,
        );
    }

    /**
     * Drive a user from Tier-2 to Tier-3 via Persona + AML.
     *
     * @param addr Subject address.
     */
    async function tier3Complete(addr: string): Promise<void> {
        const ts = await time.latest();
        await kycTiers.connect(admin).submitPersonaVerificationFor(
            addr, h(`persona:${addr}`),
            ethers.ZeroHash, ts, generateNonce(`persona-${addr}`),
            ts + 3600, MOCK_SIG,
        );
        await kycTiers.connect(admin).submitAMLClearance(
            addr, true,
            ethers.ZeroHash, ts, generateNonce(`aml-${addr}`),
            ts + 3600, MOCK_SIG,
        );
    }

    beforeEach(async function () {
        [owner, admin, user1, user2, provider1, otherAccount]
            = await ethers.getSigners();

        // DigestLib + mock gateway + mock verifier.
        const Lib = await ethers.getContractFactory('OmniRegistrationDigestLib');
        lib = await Lib.deploy();
        await lib.waitForDeployment();
        const libAddr = await lib.getAddress();

        const Gateway = await ethers.getContractFactory('MockGatewayForDecent');
        mockGateway = await Gateway.deploy();
        await mockGateway.waitForDeployment();

        const Verifier = await ethers.getContractFactory('MockBridgeVerifier');
        mockVerifier = await Verifier.deploy();
        await mockVerifier.waitForDeployment();
        await mockVerifier.setVerify(true, []);
        await mockGateway.setCommitteeVerifier(await mockVerifier.getAddress());

        // Base OmniRegistration.
        const Registration = await ethers.getContractFactory(
            'OmniRegistration',
            { libraries: { OmniRegistrationDigestLib: libAddr } },
        );
        registration = await upgrades.deployProxy(Registration, [], {
            kind: 'uups',
            initializer: 'initialize',
            constructorArgs: [ethers.ZeroAddress],
            unsafeAllowLinkedLibraries: true,
        });
        await registration.waitForDeployment();
        await registration.grantRole(VALIDATOR_ROLE, admin.address);
        await registration.setAttestationGateway(await mockGateway.getAddress());

        // KYCTiers proxy.
        const KYCTiers = await ethers.getContractFactory(
            'OmniRegistrationKYCTiers',
            { libraries: { OmniRegistrationDigestLib: libAddr } },
        );
        kycTiers = await upgrades.deployProxy(
            KYCTiers,
            [
                owner.address,
                await registration.getAddress(),
                await mockGateway.getAddress(),
            ],
            {
                kind: 'uups',
                initializer: 'initialize',
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllowLinkedLibraries: true,
            },
        );
        await kycTiers.waitForDeployment();

        // Wire KYCTIERS_ROLE + the kycTiersContract singleton binding on
        // Base so cross-contract callbacks land.
        const kycTiersAddr = await kycTiers.getAddress();
        await registration.grantRole(KYCTIERS_ROLE, kycTiersAddr);
        await registration.setKycTiersContract(kycTiersAddr);

        // Seed user1 + user2 with Tier-1 + register provider1 as a
        // trusted KYC provider on KYCTiers (admin-only).
        await registerAndTier1(user1.address);
        await registerAndTier1(user2.address);
    });

    // ═════════════════════════════════════════════════════════════════
    //                  KYC Tier 2 — ID / Address / Selfie
    // ═════════════════════════════════════════════════════════════════

    describe('KYC Tier 2 — ID Verification', function () {
        it('should complete ID verification (records hash + country)', async function () {
            const ts = await time.latest();
            const idHash = h('passport:user1-id-happy');
            const tx = await kycTiers.connect(admin).submitIDVerificationFor(
                user1.address, idHash, 'US',
                ethers.ZeroHash, ts, generateNonce('id-happy'),
                ts + 3600, MOCK_SIG,
            );
            await expect(tx).to.emit(kycTiers, 'IDVerified');
            expect(await kycTiers.userIDHashes(user1.address)).to.equal(idHash);
            expect(await kycTiers.usedIDHashes(idHash)).to.equal(true);
            expect(await kycTiers.userCountries(user1.address)).to.equal('US');
        });

        it('should reject ID verification without KYC Tier 1', async function () {
            // Register user without Tier-1 promotion.
            await registration.connect(admin).registerUser(
                otherAccount.address,
                ZeroAddress,
                h('phone:no-tier1'),
                h('email:no-tier1'),
                ethers.ZeroHash,
            );
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitIDVerificationFor(
                    otherAccount.address, h('passport:no-tier1'), 'US',
                    ethers.ZeroHash, ts, generateNonce('no-tier1'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'PreviousTierRequired');
        });

        it('should reject duplicate ID hash', async function () {
            const ts = await time.latest();
            const idHash = h('passport:shared');
            await kycTiers.connect(admin).submitIDVerificationFor(
                user1.address, idHash, 'US',
                ethers.ZeroHash, ts, generateNonce('dup-first'),
                ts + 3600, MOCK_SIG,
            );
            await expect(
                kycTiers.connect(admin).submitIDVerificationFor(
                    user2.address, idHash, 'US',
                    ethers.ZeroHash, ts, generateNonce('dup-second'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'IDAlreadyUsed');
        });

        it('should reject ID verification for an unregistered subject', async function () {
            const ghost = ethers.Wallet.createRandom();
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitIDVerificationFor(
                    ghost.address, h('passport:ghost'), 'US',
                    ethers.ZeroHash, ts, generateNonce('ghost'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'NotRegistered');
        });

        it('hasKycTier2 returns false before verification', async function () {
            expect(await kycTiers.hasKycTier2(user1.address)).to.equal(false);
        });
    });

    describe('KYC Tier 2 — completion + bumpKycTier callback', function () {
        it('completes Tier 2 after ID + Address + Selfie and bumps Base.kycTier', async function () {
            await tier2Complete(user1.address);
            expect(await kycTiers.hasKycTier2(user1.address)).to.equal(true);
            expect(await kycTiers.kycTier2CompletedAt(user1.address))
                .to.be.greaterThan(0);
            // Cross-contract callback landed on Base.
            const reg = await registration.getRegistration(user1.address);
            expect(reg.kycTier).to.equal(2);
        });

        it('Selfie requires prior ID verification', async function () {
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitSelfieVerificationFor(
                    user1.address, h('selfie:no-id'), 95,
                    ethers.ZeroHash, ts, generateNonce('selfie-no-id'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'IDVerificationRequired');
        });

        it('Selfie rejects sub-threshold similarity', async function () {
            // ID first so selfie passes the ID-required gate.
            const ts = await time.latest();
            await kycTiers.connect(admin).submitIDVerificationFor(
                user1.address, h('passport:user1-sub'), 'US',
                ethers.ZeroHash, ts, generateNonce('id-sub'),
                ts + 3600, MOCK_SIG,
            );
            await expect(
                kycTiers.connect(admin).submitSelfieVerificationFor(
                    user1.address, h('selfie:sub-thresh'),
                    50,                              // < MIN_SELFIE_SIMILARITY (85)
                    ethers.ZeroHash, ts, generateNonce('selfie-sub'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'InsufficientSimilarity');
        });
    });

    // ═════════════════════════════════════════════════════════════════
    //                  KYC Tier 3 — Persona + AML
    // ═════════════════════════════════════════════════════════════════

    describe('KYC Tier 3 — Persona + AML', function () {
        beforeEach(async function () {
            // Drive user1 to Tier 2 so Persona's prereq passes.
            await tier2Complete(user1.address);
        });

        it('should complete Persona verification', async function () {
            const ts = await time.latest();
            const personaHash = h('persona:user1-happy');
            const tx = await kycTiers.connect(admin).submitPersonaVerificationFor(
                user1.address, personaHash,
                ethers.ZeroHash, ts, generateNonce('persona-happy'),
                ts + 3600, MOCK_SIG,
            );
            await expect(tx).to.emit(kycTiers, 'PersonaVerified');
            expect(await kycTiers.personaVerificationHashes(user1.address))
                .to.equal(personaHash);
        });

        it('should complete AML clearance', async function () {
            const ts = await time.latest();
            const tx = await kycTiers.connect(admin).submitAMLClearance(
                user1.address, true,
                ethers.ZeroHash, ts, generateNonce('aml-happy'),
                ts + 3600, MOCK_SIG,
            );
            await expect(tx).to.emit(kycTiers, 'AMLCleared');
            expect(await kycTiers.amlCleared(user1.address)).to.equal(true);
            expect(await kycTiers.amlClearedAt(user1.address)).to.be.greaterThan(0);
        });

        it('completes Tier 3 when both Persona and AML are done — bumps Base.kycTier to 3', async function () {
            await tier3Complete(user1.address);
            expect(await kycTiers.hasKycTier3(user1.address)).to.equal(true);
            const reg = await registration.getRegistration(user1.address);
            expect(reg.kycTier).to.equal(3);
        });

        it('does NOT complete Tier 3 with only Persona', async function () {
            const ts = await time.latest();
            await kycTiers.connect(admin).submitPersonaVerificationFor(
                user1.address, h('persona:only'),
                ethers.ZeroHash, ts, generateNonce('only-persona'),
                ts + 3600, MOCK_SIG,
            );
            expect(await kycTiers.hasKycTier3(user1.address)).to.equal(false);
        });

        it('does NOT complete Tier 3 with only AML', async function () {
            const ts = await time.latest();
            await kycTiers.connect(admin).submitAMLClearance(
                user1.address, true,
                ethers.ZeroHash, ts, generateNonce('only-aml'),
                ts + 3600, MOCK_SIG,
            );
            expect(await kycTiers.hasKycTier3(user1.address)).to.equal(false);
        });

        it('AML cleared=false does NOT complete Tier 3', async function () {
            const ts = await time.latest();
            await kycTiers.connect(admin).submitPersonaVerificationFor(
                user1.address, h('persona:cleared-false'),
                ethers.ZeroHash, ts, generateNonce('persona-cf'),
                ts + 3600, MOCK_SIG,
            );
            await kycTiers.connect(admin).submitAMLClearance(
                user1.address, false,
                ethers.ZeroHash, ts, generateNonce('aml-cf'),
                ts + 3600, MOCK_SIG,
            );
            expect(await kycTiers.hasKycTier3(user1.address)).to.equal(false);
        });

        it('Persona rejects subject below Tier 2', async function () {
            // user2 is only Tier 1 in this describe (only user1 promoted).
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitPersonaVerificationFor(
                    user2.address, h('persona:no-t2'),
                    ethers.ZeroHash, ts, generateNonce('persona-no-t2'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'PreviousTierRequired');
        });

        it('relay-path: any caller can submitPersonaVerificationFor', async function () {
            // submitPersonaVerificationFor has no role guard — the
            // gateway is the trust surface. Use otherAccount as the
            // relayer; the call still succeeds.
            const ts = await time.latest();
            const tx = await kycTiers.connect(otherAccount).submitPersonaVerificationFor(
                user1.address, h('persona:relayed'),
                ethers.ZeroHash, ts, generateNonce('persona-relay'),
                ts + 3600, MOCK_SIG,
            );
            await expect(tx).to.emit(kycTiers, 'PersonaVerified');
        });
    });

    // ═════════════════════════════════════════════════════════════════
    //                  Accredited Investor (Tier 3 + Persona)
    // ═════════════════════════════════════════════════════════════════

    describe('Accredited Investor certification', function () {
        beforeEach(async function () {
            await tier2Complete(user1.address);
            // Persona required as the prereq (audit M-01 also requires
            // `_ensureRegistered`, satisfied via Tier-1 plumbing).
            const ts = await time.latest();
            await kycTiers.connect(admin).submitPersonaVerificationFor(
                user1.address, h('persona:accred'),
                ethers.ZeroHash, ts, generateNonce('persona-accred'),
                ts + 3600, MOCK_SIG,
            );
        });

        it('should submit accredited investor as accredited', async function () {
            const ts = await time.latest();
            await kycTiers.connect(admin).submitAccreditedInvestorCertificationFor(
                user1.address, 1, true,
                ethers.ZeroHash, ts, generateNonce('accred-true'),
                ts + 3600, MOCK_SIG,
            );
            expect(await kycTiers.isAccreditedInvestor(user1.address)).to.equal(true);
            expect(await kycTiers.accreditedInvestorCriteria(user1.address)).to.equal(1);
        });

        it('should submit accredited investor as NOT accredited', async function () {
            const ts = await time.latest();
            await kycTiers.connect(admin).submitAccreditedInvestorCertificationFor(
                user1.address, 1, false,
                ethers.ZeroHash, ts, generateNonce('accred-false'),
                ts + 3600, MOCK_SIG,
            );
            expect(await kycTiers.isAccreditedInvestor(user1.address)).to.equal(false);
        });

        it('rejects accredited investor without Persona', async function () {
            // user2 is Tier 1, no Persona yet.
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitAccreditedInvestorCertificationFor(
                    user2.address, 1, true,
                    ethers.ZeroHash, ts, generateNonce('accred-no-persona'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'PreviousTierRequired');
        });

        it('rejects accredited investor for unregistered subject (audit M-01)', async function () {
            const ghost = ethers.Wallet.createRandom();
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitAccreditedInvestorCertificationFor(
                    ghost.address, 1, true,
                    ethers.ZeroHash, ts, generateNonce('accred-ghost'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'NotRegistered');
        });
    });

    // ═════════════════════════════════════════════════════════════════
    //                  KYC Tier 4 — Third-Party KYC
    // ═════════════════════════════════════════════════════════════════

    describe('KYC Tier 4 — Third-Party KYC', function () {
        beforeEach(async function () {
            // Drive user1 all the way to Tier 3 + register a trusted
            // provider on KYCTiers.
            await tier2Complete(user1.address);
            await tier3Complete(user1.address);
            await kycTiers.connect(owner).addKYCProvider(provider1.address, 'TestKYC');
        });

        /**
         * Build a Tier-4 third-party-KYC attestation signed by the trusted
         * provider — `submitThirdPartyKYCFor` does NOT route through the
         * gateway; instead it verifies the provider's ECDSA signature
         * directly against the typed-data digest.
         *
         * @param subject  Subject address.
         * @param nonceStr Nonce string.
         * @returns Signed payload tuple ready to spread into the call.
         */
        async function buildTier4Sig(
            subject: string,
            nonceStr: string,
        ): Promise<{
            timestamp: number;
            nonce: string;
            deadline: number;
            sig: string;
        }> {
            const ts = await time.latest();
            const nonce = generateNonce(nonceStr);
            const deadline = ts + 3600;
            const domain = {
                name: 'OmniRegistrationKYCTiers',
                version: '1',
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await kycTiers.getAddress(),
            };
            const types = {
                ThirdPartyKYC: [
                    { name: 'user', type: 'address' },
                    { name: 'provider', type: 'address' },
                    { name: 'supersedes', type: 'bytes32' },
                    { name: 'timestamp', type: 'uint256' },
                    { name: 'nonce', type: 'bytes32' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };
            const value = {
                user: subject,
                provider: provider1.address,
                supersedes: ethers.ZeroHash,
                timestamp: ts,
                nonce: nonce,
                deadline: deadline,
            };
            const sig = await provider1.signTypedData(domain, types, value);
            return { timestamp: ts, nonce, deadline, sig };
        }

        it('should complete third-party KYC (KYC Tier 4)', async function () {
            const { timestamp, nonce, deadline, sig } = await buildTier4Sig(
                user1.address, 't4-happy',
            );
            const tx = await kycTiers.connect(admin).submitThirdPartyKYCFor(
                user1.address, provider1.address,
                ethers.ZeroHash, timestamp, nonce, deadline, sig,
            );
            await expect(tx).to.emit(kycTiers, 'KycTier4Completed');
            expect(await kycTiers.hasKycTier4(user1.address)).to.equal(true);
            expect(await kycTiers.userKYCProvider(user1.address))
                .to.equal(provider1.address);
            // Cross-contract bump to Base.kycTier = 4.
            const reg = await registration.getRegistration(user1.address);
            expect(reg.kycTier).to.equal(4);
        });

        it('rejects third-party KYC from untrusted provider', async function () {
            // Use otherAccount as a fake "provider" not registered via
            // addKYCProvider. The contract checks
            // `trustedKYCProviders[provider]` BEFORE signature recovery;
            // a zero-byte signature is enough to trip the gate.
            const ts = await time.latest();
            await expect(
                kycTiers.connect(admin).submitThirdPartyKYCFor(
                    user1.address, otherAccount.address,
                    ethers.ZeroHash, ts, generateNonce('untrusted'),
                    ts + 3600, MOCK_SIG,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'UntrustedKYCProvider');
        });

        it('rejects third-party KYC without Tier 3', async function () {
            // user2 only has Tier 1.
            const { timestamp, nonce, deadline, sig } = await buildTier4Sig(
                user2.address, 't4-no-t3',
            );
            await expect(
                kycTiers.connect(admin).submitThirdPartyKYCFor(
                    user2.address, provider1.address,
                    ethers.ZeroHash, timestamp, nonce, deadline, sig,
                ),
            ).to.be.revertedWithCustomError(kycTiers, 'PreviousTierRequired');
        });

        it('hasKycTier4 returns false before verification', async function () {
            // user2 has no Tier 4 attestation.
            expect(await kycTiers.hasKycTier4(user2.address)).to.equal(false);
        });
    });

    describe('KYC Provider Management', function () {
        it('admin can add KYC provider', async function () {
            const tx = await kycTiers.connect(owner).addKYCProvider(
                provider1.address, 'NewProvider',
            );
            await expect(tx)
                .to.emit(kycTiers, 'KYCProviderAdded')
                .withArgs(provider1.address, 'NewProvider');
            expect(await kycTiers.trustedKYCProviders(provider1.address))
                .to.equal(true);
            expect(await kycTiers.kycProviderNames(provider1.address))
                .to.equal('NewProvider');
        });

        it('admin can remove KYC provider', async function () {
            await kycTiers.connect(owner).addKYCProvider(provider1.address, 'P1');
            const tx = await kycTiers.connect(owner).removeKYCProvider(provider1.address);
            await expect(tx).to.emit(kycTiers, 'KYCProviderRemoved').withArgs(provider1.address);
            expect(await kycTiers.trustedKYCProviders(provider1.address))
                .to.equal(false);
        });

        it('rejects adding zero address as provider', async function () {
            await expect(
                kycTiers.connect(owner).addKYCProvider(ZeroAddress, 'Zero'),
            ).to.be.revertedWithCustomError(kycTiers, 'InvalidProvider');
        });

        it('rejects unauthorized provider management', async function () {
            await expect(
                kycTiers.connect(otherAccount).addKYCProvider(
                    provider1.address, 'Unauthorized',
                ),
            ).to.be.reverted; // AccessControl revert
            await expect(
                kycTiers.connect(otherAccount).removeKYCProvider(provider1.address),
            ).to.be.reverted;
        });
    });

    // ═════════════════════════════════════════════════════════════════
    //                  Relay pattern — anyone can submit*For
    // ═════════════════════════════════════════════════════════════════

    describe('Relay pattern', function () {
        it('any caller can relay submitIDVerificationFor without VALIDATOR_ROLE', async function () {
            // Use otherAccount as the relayer — has NO roles on either
            // contract. The relay-pattern docstring is that the trust
            // surface is the EIP-712 envelope verified by the gateway,
            // not msg.sender.
            const ts = await time.latest();
            const tx = await kycTiers.connect(otherAccount).submitIDVerificationFor(
                user1.address, h('passport:relay'), 'US',
                ethers.ZeroHash, ts, generateNonce('relay-id'),
                ts + 3600, MOCK_SIG,
            );
            await expect(tx).to.emit(kycTiers, 'IDVerified');
            // Tier 2 not yet complete because Address + Selfie missing.
            expect(await kycTiers.hasKycTier2(user1.address)).to.equal(false);
        });
    });
});
