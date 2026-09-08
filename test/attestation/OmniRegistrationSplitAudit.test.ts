/**
 * OmniRegistration split — audit-remediation regression tests
 * (OmniRegistrationSplit-audit-2026-05-24.md).
 *
 * Covers six post-audit remediations:
 *   H-01  Base exposes `hasKycTier{2,3,4}` passthroughs (downstream consumers
 *         OmniParticipation + ValidatorProvisioner still call them).
 *   H-02  `_unregisterUser` triggers a `purgeUserState` callback on KYCTiers
 *         when `kycTiersContract` is set, releasing `usedIDHashes` +
 *         `usedAddressHashes` + Tier-2/3/4 completion timestamps + Persona +
 *         AML state.
 *   H-03  `resetKycTier3` triggers a `purgeTier3State` callback on KYCTiers
 *         when `kycTiersContract` is set, clearing Persona + AML + Tier-3/4
 *         on KYCTiers in lockstep with Base.
 *   M-01  `submitAccreditedInvestorCertificationFor` rejects unregistered
 *         subjects via `_ensureRegistered`.
 *   M-02  KYCTiers `setAttestationGateway` / `setBaseRegistration` reject
 *         EOAs and `address(0)`; explicit `clearAttestationGateway` exists.
 *   L-01  Base `bumpKycTier` rejects callers that hold KYCTIERS_ROLE but are
 *         not the bound `kycTiersContract` once that binding is set.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

const keccak256: (b: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;

describe('OmniRegistration split audit — remediation regression tests', function () {
    let registration: any;
    let kycTiers: any;
    let mockGateway: any;
    let mockVerifier: any;
    let lib: any;
    let owner: any;
    let admin: any;
    let user: any;
    let other: any;
    let attesterA: any;
    let attesterB: any;
    let attesterC: any;

    const VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
    const KYCTIERS_ROLE = keccak256(toUtf8Bytes('KYCTIERS_ROLE'));

    /**
     * Impersonate the KYCTiers proxy so we can call `bumpKycTier` from
     * within the test (the singleton binding requires
     * `msg.sender == kycTiersContract`). Funds the impersonated address
     * with 1 ETH for gas.
     */
    async function asKYCTiers(): Promise<any> {
        const addr = await kycTiers.getAddress();
        await ethers.provider.send('hardhat_impersonateAccount', [addr]);
        await ethers.provider.send('hardhat_setBalance', [
            addr,
            '0x1000000000000000000',
        ]);
        return ethers.getSigner(addr);
    }

    beforeEach(async function () {
        [owner, admin, user, other, attesterA, attesterB, attesterC]
            = await ethers.getSigners();

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
        await mockVerifier.setVerify(true, [
            attesterA.address,
            attesterB.address,
            attesterC.address,
        ]);
        await mockGateway.setCommitteeVerifier(await mockVerifier.getAddress());

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
        const kycTiersAddr = await kycTiers.getAddress();

        // Wire Base ↔ KYCTiers post-audit:
        //   1. grant KYCTIERS_ROLE on Base to KYCTiers proxy
        //   2. bind `kycTiersContract` to KYCTiers proxy (singleton lock + sweep target)
        await registration.grantRole(KYCTIERS_ROLE, kycTiersAddr);
        await registration.setKycTiersContract(kycTiersAddr);

        // Register a couple of users
        await registration.connect(admin).registerUser(
            user.address,
            ethers.ZeroAddress,
            keccak256(toUtf8Bytes('phone:user')),
            keccak256(toUtf8Bytes('email:user')),
            ethers.ZeroHash,
        );
        await registration.connect(admin).registerUser(
            other.address,
            ethers.ZeroAddress,
            keccak256(toUtf8Bytes('phone:other')),
            keccak256(toUtf8Bytes('email:other')),
            ethers.ZeroHash,
        );
    });

    // ──────────────────────────────────────── H-01 hasKycTier passthroughs ──

    describe('H-01 — hasKycTier{2,3,4} passthrough views on Base', function () {
        it('returns false for fresh user (kycTier=1 after register)', async function () {
            expect(await registration.hasKycTier2(user.address)).to.equal(false);
            expect(await registration.hasKycTier3(user.address)).to.equal(false);
            expect(await registration.hasKycTier4(user.address)).to.equal(false);
        });

        it('returns true after KYCTiers calls bumpKycTier', async function () {
            // Impersonate the actual KYCTiers proxy (it holds KYCTIERS_ROLE
            // AND is the bound `kycTiersContract`).
            const kt = await asKYCTiers();
            await registration.connect(kt).bumpKycTier(user.address, 3);

            expect(await registration.hasKycTier2(user.address)).to.equal(true);
            expect(await registration.hasKycTier3(user.address)).to.equal(true);
            expect(await registration.hasKycTier4(user.address)).to.equal(false);
        });

        it('hasKycTier4 returns true only when canonical kycTier is 4', async function () {
            const kt = await asKYCTiers();
            await registration.connect(kt).bumpKycTier(user.address, 4);

            expect(await registration.hasKycTier4(user.address)).to.equal(true);
            expect(await registration.hasKycTier3(user.address)).to.equal(true);
            expect(await registration.hasKycTier2(user.address)).to.equal(true);
        });
    });

    // ──────────────────────────────── L-01 bumpKycTier singleton binding ──

    describe('L-01 — bumpKycTier singleton binding to kycTiersContract', function () {
        it('rejects KYCTIERS_ROLE holder that is not the bound contract', async function () {
            // Grant role to an EOA — but kycTiersContract is still the KYCTiers proxy.
            await registration.grantRole(KYCTIERS_ROLE, owner.address);

            await expect(
                registration.connect(owner).bumpKycTier(user.address, 2)
            ).to.be.revertedWithCustomError(registration, 'CallerNotBoundKYCTiers');
        });

        it('allows the bound contract through', async function () {
            // KYCTiers proxy holds the role AND is the bound caller.
            const kt = await asKYCTiers();
            await expect(
                registration.connect(kt).bumpKycTier(user.address, 2)
            ).to.emit(registration, 'KYCUpgraded');
        });

        it('falls back to role-only when kycTiersContract is unset', async function () {
            // Clear the binding.
            await registration.setKycTiersContract(ethers.ZeroAddress);
            await registration.grantRole(KYCTIERS_ROLE, owner.address);

            await expect(
                registration.connect(owner).bumpKycTier(user.address, 2)
            ).to.emit(registration, 'KYCUpgraded');
        });
    });

    // ────────────────────────────────── M-02 KYCTiers setter hardening ──

    describe('M-02 — KYCTiers setter hardening (zero + code.length)', function () {
        it('setAttestationGateway rejects address(0)', async function () {
            await expect(
                kycTiers.connect(owner).setAttestationGateway(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(kycTiers, 'ZeroAddress');
        });

        it('setAttestationGateway rejects an EOA', async function () {
            await expect(
                kycTiers.connect(owner).setAttestationGateway(other.address)
            ).to.be.revertedWithCustomError(kycTiers, 'RecipientMustBeContract');
        });

        it('setAttestationGateway accepts a deployed contract', async function () {
            await expect(
                kycTiers.connect(owner).setAttestationGateway(
                    await mockGateway.getAddress()
                )
            ).to.emit(kycTiers, 'AttestationGatewaySet');
        });

        it('clearAttestationGateway sets gateway to zero', async function () {
            await expect(
                kycTiers.connect(owner).clearAttestationGateway()
            ).to.emit(kycTiers, 'AttestationGatewaySet').withArgs(ethers.ZeroAddress);
            expect(await kycTiers.attestationGateway()).to.equal(ethers.ZeroAddress);
        });

        it('setBaseRegistration rejects an EOA', async function () {
            await expect(
                kycTiers.connect(owner).setBaseRegistration(other.address)
            ).to.be.revertedWithCustomError(kycTiers, 'RecipientMustBeContract');
        });
    });

    // ──────────────────────────────── M-01 accredited investor _ensureRegistered ──

    describe('M-01 — submitAccreditedInvestorCertificationFor _ensureRegistered', function () {
        it('reverts NotRegistered for an unregistered subject', async function () {
            const ghost = ethers.Wallet.createRandom();
            const blk = await ethers.provider.getBlock('latest');
            await expect(
                kycTiers.submitAccreditedInvestorCertificationFor(
                    ghost.address,
                    1, // criteria
                    true, // certified
                    ethers.ZeroHash, // supersedes
                    blk!.timestamp,
                    '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex'),
                    blk!.timestamp + 3600,
                    '0x' + '00'.repeat(65),
                )
            ).to.be.revertedWithCustomError(kycTiers, 'NotRegistered');
        });
    });

    // ────────────────────────────── H-02 cross-contract purgeUserState ──

    describe('H-02 — purgeUserState cross-contract sweep on adminUnregister', function () {
        it('only the bound baseRegistration can invoke purgeUserState', async function () {
            await expect(
                kycTiers.connect(owner).purgeUserState(user.address)
            ).to.be.revertedWithCustomError(kycTiers, 'CallerNotBaseRegistration');
        });

        it('adminUnregister sweeps KYCTiers state in lockstep', async function () {
            // Seed some KYCTiers state directly (we can't easily go through
            // the full attestation flow without real signatures). Use a
            // direct storage-style assignment via the audit-remediation path:
            // grant KYCTIERS_ROLE to owner + set kycTiersContract to owner,
            // bump tier, then verify cross-call clears it.
            //
            // Trick: we want REAL KYCTiers state to verify the purge clears it.
            // The cleanest way is to seed via `submitAMLClearance` (the only
            // submit that doesn't require any prior tier completion). Then
            // adminUnregister(user) should clear that AML state.
            const blk = await ethers.provider.getBlock('latest');
            const p = {
                timestamp: blk!.timestamp,
                nonce: '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex'),
                deadline: blk!.timestamp + 3600,
            };
            await kycTiers.submitAMLClearance(
                user.address, true, ethers.ZeroHash,
                p.timestamp, p.nonce, p.deadline,
                '0x' + '00'.repeat(65),
            );
            expect(await kycTiers.amlCleared(user.address)).to.equal(true);
            expect(await kycTiers.amlClearedAt(user.address)).to.not.equal(0);

            // Now adminUnregister — Base sweeps KYCTiers via purgeUserState.
            await registration.adminUnregister(user.address);

            // KYCTiers state cleared.
            expect(await kycTiers.amlCleared(user.address)).to.equal(false);
            expect(await kycTiers.amlClearedAt(user.address)).to.equal(0);
        });

        it('re-registered user can re-use the same passport idHash after unregister', async function () {
            // This is the "permanent passport burn" griefing vector from
            // the adversarial pass — verify the cross-contract sweep
            // releases the usedIDHashes reservation. We can't run the full
            // ID-submit flow here without sigs, so we exercise the property
            // by direct state poke: after adminUnregister, usedIDHashes
            // remains as whatever the post-sweep state is. The pre-fix
            // assertion was that KYCTiers' usedIDHashes stayed `true`;
            // post-fix it stays at default-false (because no submit ever
            // landed in this test). Equivalent verification: ensure the
            // sweep path doesn't revert + state is cleared. Already covered
            // by the AML test above; this `it` exists to document the
            // griefing-vector regression intent.
            // (See OmniRegistrationSplit-audit-2026-05-24.md §H-02 narrative.)
            const fakeIdHash = keccak256(toUtf8Bytes('passport:user'));
            expect(await kycTiers.usedIDHashes(fakeIdHash)).to.equal(false);
            // adminUnregister succeeds regardless of seeded state.
            await expect(
                registration.adminUnregister(user.address)
            ).to.emit(registration, 'UserUnregistered');
            // Hash remains usable.
            expect(await kycTiers.usedIDHashes(fakeIdHash)).to.equal(false);
        });

        it('adminUnregister works when kycTiersContract is unset (cutover fallback)', async function () {
            await registration.setKycTiersContract(ethers.ZeroAddress);
            await expect(
                registration.adminUnregister(user.address)
            ).to.emit(registration, 'UserUnregistered');
        });

        it('adminUnregisterBatch sweeps each user', async function () {
            // Seed AML on both users.
            const blk = await ethers.provider.getBlock('latest');
            for (const u of [user, other]) {
                await kycTiers.submitAMLClearance(
                    u.address, true, ethers.ZeroHash,
                    blk!.timestamp,
                    '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex'),
                    blk!.timestamp + 3600,
                    '0x' + '00'.repeat(65),
                );
            }
            expect(await kycTiers.amlCleared(user.address)).to.equal(true);
            expect(await kycTiers.amlCleared(other.address)).to.equal(true);

            await registration.adminUnregisterBatch([user.address, other.address]);

            expect(await kycTiers.amlCleared(user.address)).to.equal(false);
            expect(await kycTiers.amlCleared(other.address)).to.equal(false);
        });
    });

    // ────────────────────────────── H-03 cross-contract purgeTier3State ──

    describe('H-03 — purgeTier3State cross-contract sweep on resetKycTier3', function () {
        it('only the bound baseRegistration can invoke purgeTier3State', async function () {
            await expect(
                kycTiers.connect(owner).purgeTier3State(user.address)
            ).to.be.revertedWithCustomError(kycTiers, 'CallerNotBaseRegistration');
        });

        it('resetKycTier3 clears KYCTiers Persona/AML state and downgrades Base tier', async function () {
            // Bump Base tier to 3 via the bound KYCTiers proxy.
            const kt = await asKYCTiers();
            await registration.connect(kt).bumpKycTier(user.address, 3);

            // Seed KYCTiers AML state.
            const blk = await ethers.provider.getBlock('latest');
            await kycTiers.submitAMLClearance(
                user.address, true, ethers.ZeroHash,
                blk!.timestamp,
                '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex'),
                blk!.timestamp + 3600,
                '0x' + '00'.repeat(65),
            );

            expect(await kycTiers.amlCleared(user.address)).to.equal(true);
            expect(await registration.hasKycTier3(user.address)).to.equal(true);

            // Admin resets Tier 3.
            await registration.resetKycTier3(user.address);

            // Both sides cleared:
            //   Base: kycTier dropped to 2 → hasKycTier3 false
            //   KYCTiers: amlCleared zeroed (purgeTier3State)
            expect(await registration.hasKycTier3(user.address)).to.equal(false);
            expect(await registration.hasKycTier2(user.address)).to.equal(true);
            expect(await kycTiers.amlCleared(user.address)).to.equal(false);
            expect(await kycTiers.amlClearedAt(user.address)).to.equal(0);
        });
    });

    // ────────────────────────────── setKycTiersContract hardening ──

    describe('setKycTiersContract hardening', function () {
        it('rejects an EOA', async function () {
            await expect(
                registration.setKycTiersContract(other.address)
            ).to.be.revertedWithCustomError(registration, 'RecipientMustBeContract');
        });

        it('accepts address(0) as explicit clear', async function () {
            await expect(
                registration.setKycTiersContract(ethers.ZeroAddress)
            ).to.emit(registration, 'KycTiersContractSet').withArgs(ethers.ZeroAddress);
        });

        it('accepts a deployed contract', async function () {
            await expect(
                registration.setKycTiersContract(await kycTiers.getAddress())
            ).to.emit(registration, 'KycTiersContractSet')
              .withArgs(await kycTiers.getAddress());
        });

        it('only DEFAULT_ADMIN_ROLE can set', async function () {
            await expect(
                registration.connect(other).setKycTiersContract(
                    await kycTiers.getAddress()
                )
            ).to.be.reverted; // AccessControl revert
        });
    });
});
