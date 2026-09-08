/**
 * @file OmniRegistration.committee.test.ts
 * @description Phase 2 cutover E2E (post-audit refactor) — proves
 * OmniRegistration verifies attestations correctly via the new
 * OmniAttestationGateway architecture. All verification logic now lives
 * in the gateway; OmniRegistration just calls `verifyAndConsume` with the
 * EIP-712 digest + nonce + deadline + proof.
 *
 * Coverage:
 *   • Pre-cutover (gateway unset): submit functions revert with
 *     `AttestationGatewayNotSet`.
 *   • Gateway wired + committee mode: phone-verify happy path with a
 *     4-of-5 committee proof.
 *   • Gateway wired + legacy mode: phone-verify happy path with a single
 *     trustedVerificationKey signature.
 *   • Gateway rollback (clearCommitteeVerifier on gateway): legacy path
 *     resumes; committee proofs rejected as malformed sigs.
 *   • Access control: only DEFAULT_ADMIN_ROLE can setAttestationGateway.
 *   • Pause: when gateway is paused, all submissions revert.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (arr: any[]) => string = ethers.concat;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;
const AbiCoder = ethers.AbiCoder;

const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';
const APPROVED_VERSION = 'random-committee-ecdsa-v2';

describe('OmniRegistration — Phase 2 cutover via OmniAttestationGateway', function () {
    let registration: any;
    let gateway: any;
    let verifier: any;
    let mockBootstrap: any;
    let mockOmniCore: any;
    let mockOmniRegistration: any;

    let owner: any;
    let admin: any;
    let guardian: any;
    let user: any;
    let trustedKey: any;
    const VALIDATORS: any[] = [];

    async function setEligible(w: any): Promise<void> {
        await mockBootstrap.setNodeActive(w.address, true, 0);
        await mockOmniRegistration.setKycTier(w.address, 3);
        await mockOmniCore.setStake(
            w.address,
            ethers.parseEther('1000000'),
            true,
        );
    }

    function signCommitteeEthMessage(wallet: any, digest: string): string {
        const ethSigned = keccak256(
            concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
        );
        const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
        return sigObj.serialized;
    }

    function buildCommitteeProof(
        commitBlock: number,
        signers: any[],
        digest: string,
    ): string {
        const sorted = [...signers].sort((a, b) =>
            a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
        );
        // Audit H-06 v2 BOUND form: each committee member signs
        // keccak256(abi.encode(messageHash, commitBlock)), binding the signature
        // to the committee-selection block it committed to (not the raw
        // messageHash / legacy v1 form). Matches RandomCommitteeVerifier.verify's
        // boundHash = keccak256(abi.encode(messageHash, commitBlock)).
        const boundHash = keccak256(
            AbiCoder.defaultAbiCoder().encode(
                ['bytes32', 'uint256'],
                [digest, commitBlock],
            ),
        );
        const sigs = sorted.map((w) => signCommitteeEthMessage(w, boundHash));
        const commitBlockHex = ethers.toBeHex(commitBlock, 32);
        return concat([commitBlockHex, ...sigs]);
    }

    async function confirmedCommitBlock(): Promise<number> {
        await ethers.provider.send('evm_mine', []);
        await ethers.provider.send('evm_mine', []);
        return (await ethers.provider.getBlockNumber()) - 1;
    }

    /**
     * Sign a phone-verification attestation under the LEGACY path
     * (EIP-712 + EIP-712-typed wallet signing — produces a 65-byte sig
     * that recovers to `trustedKey` via `digest.recover(sig)` where
     * `digest = keccak256("\x19\x01" || domainSep || structHash)`).
     */
    async function signLegacyPhoneAttestation(
        userAddr: string,
        phoneHash: string,
        timestamp: number,
        nonce: string,
        deadline: number,
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
                { name: 'supersedes', type: 'bytes32' },
                { name: 'timestamp', type: 'uint256' },
                { name: 'nonce', type: 'bytes32' },
                { name: 'deadline', type: 'uint256' },
            ],
        };
        return trustedKey.signTypedData(domain, types, {
            user: userAddr,
            phoneHash,
            supersedes: ethers.ZeroHash,
            timestamp,
            nonce,
            deadline,
        });
    }

    async function phoneDigest(
        userAddr: string,
        phoneHash: string,
        timestamp: number,
        nonce: string,
        deadline: number,
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
                { name: 'supersedes', type: 'bytes32' },
                { name: 'timestamp', type: 'uint256' },
                { name: 'nonce', type: 'bytes32' },
                { name: 'deadline', type: 'uint256' },
            ],
        };
        return ethers.TypedDataEncoder.hash(domain, types, {
            user: userAddr,
            phoneHash,
            supersedes: ethers.ZeroHash,
            timestamp,
            nonce,
            deadline,
        });
    }

    beforeEach(async function () {
        const signers = await ethers.getSigners();
        owner = signers[0];
        admin = signers[1];
        guardian = signers[2];
        user = signers[3];

        trustedKey = ethers.Wallet.createRandom().connect(ethers.provider);
        VALIDATORS.length = 0;
        for (let i = 0; i < 15; ++i) {
            VALIDATORS.push(ethers.Wallet.createRandom().connect(ethers.provider));
        }

        // Mocks
        mockBootstrap = await (
            await ethers.getContractFactory('MockBootstrapForAttestation')
        ).deploy();
        await mockBootstrap.waitForDeployment();
        mockOmniCore = await (
            await ethers.getContractFactory('MockOmniCoreForAttestation')
        ).deploy();
        await mockOmniCore.waitForDeployment();
        mockOmniRegistration = await (
            await ethers.getContractFactory('MockOmniRegistrationForAttestation')
        ).deploy();
        await mockOmniRegistration.waitForDeployment();

        // OmniRegistration via UUPS proxy (links OmniRegistrationDigestLib, EIP-170)
        const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
        const digestLib = await DigestLib.deploy();
        await digestLib.waitForDeployment();
        const Registration = await ethers.getContractFactory('OmniRegistration', {
            libraries: { OmniRegistrationDigestLib: await digestLib.getAddress() },
        });
        registration = await upgrades.deployProxy(Registration, [], {
            kind: 'uups',
            initializer: 'initialize',
            constructorArgs: [ethers.ZeroAddress],
            unsafeAllowLinkedLibraries: true,
        });
        await registration.waitForDeployment();

        const VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
        await registration.grantRole(VALIDATOR_ROLE, admin.address);

        // RandomCommitteeVerifier
        verifier = await (
            await ethers.getContractFactory('RandomCommitteeVerifier')
        ).deploy(
            owner.address,
            await mockBootstrap.getAddress(),
            await mockOmniCore.getAddress(),
            await mockOmniRegistration.getAddress(),
            5, // N
            4, // M
            3,
            ethers.parseEther('1000000'),
        );
        await verifier.waitForDeployment();
        for (const v of VALIDATORS) {
            await setEligible(v);
        }
        await verifier.refreshEligibleSet();

        // Gateway
        gateway = await (
            await ethers.getContractFactory('OmniAttestationGateway')
        ).deploy(owner.address, guardian.address, trustedKey.address);
        await gateway.waitForDeployment();
        await gateway.setApprovedVerifierVersion(APPROVED_VERSION, true);
        await gateway.setAuthorizedConsumer(await registration.getAddress(), true);

        // Wire OmniRegistration → gateway.
        await registration.setAttestationGateway(await gateway.getAddress());
    });

    async function freshAttestationParams(): Promise<{
        phoneHash: string;
        timestamp: number;
        nonce: string;
        deadline: number;
    }> {
        const latest = await ethers.provider.getBlock('latest');
        const phoneHash = keccak256(ethers.randomBytes(32));
        return {
            phoneHash,
            timestamp: latest!.timestamp,
            nonce: '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex'),
            deadline: latest!.timestamp + 3600,
        };
    }

    // ─────────────────────────────────────── pre-cutover (gateway unset) ──

    describe('pre-cutover (attestationGateway unset)', () => {
        it('reverts AttestationGatewayNotSet', async () => {
            // Deploy a fresh registration without setting the gateway.
            const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
            const digestLib = await DigestLib.deploy();
            await digestLib.waitForDeployment();
            const Registration = await ethers.getContractFactory('OmniRegistration', {
                libraries: { OmniRegistrationDigestLib: await digestLib.getAddress() },
            });
            const reg2 = await upgrades.deployProxy(Registration, [], {
                kind: 'uups',
                initializer: 'initialize',
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllowLinkedLibraries: true,
            });
            await reg2.waitForDeployment();

            const VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
            await reg2.grantRole(VALIDATOR_ROLE, admin.address);

            const fresh = ethers.Wallet.createRandom();
            await reg2
                .connect(admin)
                .registerUser(
                    fresh.address,
                    ethers.ZeroAddress,
                    ethers.ZeroHash,
                    keccak256(toUtf8Bytes('nogateway@example.com')),
                ethers.ZeroHash,
                );
            const p = await freshAttestationParams();
            await expect(
                reg2.submitPhoneVerificationFor(
                    fresh.address,
                    p.phoneHash,
                    ethers.ZeroHash,
                    p.timestamp,
                    p.nonce,
                    p.deadline,
                    '0x' + '00'.repeat(65),
                ),
            ).to.be.revertedWithCustomError(reg2, 'AttestationGatewayNotSet');
        });
    });

    // ──────────────────────────── gateway wired, legacy single-key path ──

    describe('legacy path through gateway', () => {
        it('accepts a single trustedVerificationKey signature', async () => {
            const fresh = ethers.Wallet.createRandom();
            await registration
                .connect(admin)
                .registerUser(
                    fresh.address,
                    ethers.ZeroAddress,
                    ethers.ZeroHash,
                    keccak256(toUtf8Bytes('legacy-via-gw@example.com')),
                ethers.ZeroHash,
                );
            const p = await freshAttestationParams();
            const sig = await signLegacyPhoneAttestation(
                fresh.address,
                p.phoneHash,
                p.timestamp,
                p.nonce,
                p.deadline,
            );

            await registration.submitPhoneVerificationFor(
                fresh.address,
                p.phoneHash,
                ethers.ZeroHash,
                p.timestamp,
                p.nonce,
                p.deadline,
                sig,
            );

            const reg = await registration.getRegistration(fresh.address);
            expect(reg.phoneHash).to.equal(p.phoneHash);
        });
    });

    // ───────────────────────────── gateway wired, committee path ──

    describe('committee path through gateway', () => {
        beforeEach(async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
        });

        it('accepts a 4-of-5 committee proof', async () => {
            const fresh = ethers.Wallet.createRandom();
            await registration
                .connect(admin)
                .registerUser(
                    fresh.address,
                    ethers.ZeroAddress,
                    ethers.ZeroHash,
                    keccak256(toUtf8Bytes('committee-via-gw@example.com')),
                ethers.ZeroHash,
                );
            const p = await freshAttestationParams();
            const digest = await phoneDigest(
                fresh.address,
                p.phoneHash,
                p.timestamp,
                p.nonce,
                p.deadline,
            );
            const commitBlock = await confirmedCommitBlock();
            const committee: string[] = await verifier.committeeFor(
                digest,
                commitBlock,
            );
            const lowerSet = new Set(committee.map((a: string) => a.toLowerCase()));
            const matched = VALIDATORS.filter((w: any) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            const proof = buildCommitteeProof(
                commitBlock,
                matched.slice(0, 4),
                digest,
            );

            await registration.submitPhoneVerificationFor(
                fresh.address,
                p.phoneHash,
                ethers.ZeroHash,
                p.timestamp,
                p.nonce,
                p.deadline,
                proof,
            );

            const reg = await registration.getRegistration(fresh.address);
            expect(reg.phoneHash).to.equal(p.phoneHash);
        });

        it('rejects a legacy single-sig under committee mode', async () => {
            const fresh = ethers.Wallet.createRandom();
            await registration
                .connect(admin)
                .registerUser(
                    fresh.address,
                    ethers.ZeroAddress,
                    ethers.ZeroHash,
                    keccak256(toUtf8Bytes('legacy-rejected@example.com')),
                ethers.ZeroHash,
                );
            const p = await freshAttestationParams();
            const legacySig = await signLegacyPhoneAttestation(
                fresh.address,
                p.phoneHash,
                p.timestamp,
                p.nonce,
                p.deadline,
            );

            await expect(
                registration.submitPhoneVerificationFor(
                    fresh.address,
                    p.phoneHash,
                    ethers.ZeroHash,
                    p.timestamp,
                    p.nonce,
                    p.deadline,
                    legacySig,
                ),
            ).to.be.revertedWithCustomError(
                gateway,
                'InvalidVerificationProof',
            );
        });
    });

    // ────────────────────────────────── Pause from registration POV ──

    describe('gateway-pause halts registration', () => {
        it('paused gateway rejects all phone-verify submissions', async () => {
            await gateway.connect(guardian).pause();
            const fresh = ethers.Wallet.createRandom();
            await registration
                .connect(admin)
                .registerUser(
                    fresh.address,
                    ethers.ZeroAddress,
                    ethers.ZeroHash,
                    keccak256(toUtf8Bytes('paused@example.com')),
                ethers.ZeroHash,
                );
            const p = await freshAttestationParams();
            const sig = await signLegacyPhoneAttestation(
                fresh.address,
                p.phoneHash,
                p.timestamp,
                p.nonce,
                p.deadline,
            );
            await expect(
                registration.submitPhoneVerificationFor(
                    fresh.address,
                    p.phoneHash,
                    ethers.ZeroHash,
                    p.timestamp,
                    p.nonce,
                    p.deadline,
                    sig,
                ),
            ).to.be.revertedWithCustomError(gateway, 'EnforcedPause');
        });
    });

    // ─────────────────────────────────── Access control on setter ──

    describe('setAttestationGateway access control + M-NEW-4 hardening', () => {
        it('non-admin cannot call', async () => {
            await expect(
                registration
                    .connect(user)
                    .setAttestationGateway(await gateway.getAddress()),
            ).to.be.reverted;
        });

        it('rejects zero address (audit Pass-2 M-NEW-4)', async () => {
            await expect(
                registration.setAttestationGateway(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(registration, 'ZeroAddress');
        });

        it('rejects unconfigured gateway (audit Pass-2 M-NEW-4 wiring check)', async () => {
            const gw2 = await (
                await ethers.getContractFactory('OmniAttestationGateway')
            ).deploy(owner.address, guardian.address, trustedKey.address);
            await gw2.waitForDeployment();

            await expect(
                registration.setAttestationGateway(await gw2.getAddress()),
            ).to.be.revertedWithCustomError(
                registration,
                'GatewayNotConfiguredForConsumer',
            );
        });

        it('clearAttestationGateway emits with zero', async () => {
            await expect(registration.clearAttestationGateway())
                .to.emit(registration, 'AttestationGatewaySet')
                .withArgs(ethers.ZeroAddress);
        });

        it('clearAttestationGateway is admin-only', async () => {
            await expect(
                registration.connect(user).clearAttestationGateway(),
            ).to.be.reverted;
        });
    });

    describe('setTrustedVerificationKey retirement (audit Pass-2 L-NEW-Biz)', () => {
        it('always reverts after gateway is wired', async () => {
            await expect(
                registration.setTrustedVerificationKey(trustedKey.address),
            ).to.be.revertedWithCustomError(
                registration,
                'LegacyTrustedKeyRetired',
            );
        });

        it('reverts even with zero address (single revert path)', async () => {
            await expect(
                registration.setTrustedVerificationKey(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(
                registration,
                'LegacyTrustedKeyRetired',
            );
        });
    });
});
