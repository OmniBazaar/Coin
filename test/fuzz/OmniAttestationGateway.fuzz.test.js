/**
 * @file OmniAttestationGateway.fuzz.test.js
 * @description Invariant fuzzing for OmniAttestationGateway — flash-tier
 * hardening pass. Tests 8 key invariants with randomized inputs.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

const keccak256 = ethers.keccak256;
const toUtf8Bytes = ethers.toUtf8Bytes;
const concat = ethers.concat;
const getBytes = ethers.getBytes;
const SigningKey = ethers.SigningKey;
const randomBytes = ethers.randomBytes;

const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';
const APPROVED_VERSION = 'random-committee-ecdsa-v2';

function randomBytes32() {
    return keccak256(randomBytes(32));
}

function randomAddress() {
    return ethers.getAddress(
        '0x' + Buffer.from(randomBytes(20)).toString('hex'),
    );
}

function randomUint256(min, max) {
    const range = max - min + 1n;
    const rand = BigInt('0x' + Buffer.from(randomBytes(32)).toString('hex'));
    return min + (rand % range);
}

async function confirmedCommitBlock() {
    await ethers.provider.send('evm_mine', []);
    await ethers.provider.send('evm_mine', []);
    return (await ethers.provider.getBlockNumber()) - 1;
}

/**
 * Sign a digest under the EIP-191 eth_sign envelope used by the committee
 * verifier. Matches the existing test's signCommitteeEthMessage — signs
 * the raw messageHash (unbound/legacy v1 form). The verifier accepts this
 * because legacySignaturesAccepted defaults to true.
 */
function signCommitteeEthMessage(wallet, digest) {
    const ethSigned = keccak256(
        concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
    );
    const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
    return sigObj.serialized;
}

function signLegacyRaw(wallet, digest) {
    const sigObj = new SigningKey(wallet.privateKey).sign(digest);
    return sigObj.serialized;
}

function buildCommitteeProof(commitBlock, signers, digest) {
    const sorted = [...signers].sort((a, b) =>
        a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
    );
    const sigs = sorted.map((w) => signCommitteeEthMessage(w, digest));
    const commitBlockBytes = ethers.zeroPadValue(
        ethers.toBeHex(commitBlock),
        32,
    );
    return concat([commitBlockBytes, ...sigs]);
}

describe('OmniAttestationGateway Fuzz (flash-tier)', function () {
    let gateway;
    let mockVerifier;
    let mockBootstrap;
    let mockOmniCore;
    let mockOmniRegistration;

    let owner;
    let guardian;
    let consumer;
    let outsider;
    let subject;

    const VALIDATORS = [];
    let trustedKey;

    const INITIAL_M = 4;
    const INITIAL_N = 5;

    async function setEligible(w) {
        await mockBootstrap.setNodeActive(w.address, true, 0);
        await mockOmniRegistration.setKycTier(w.address, 3);
        await mockOmniCore.setStake(
            w.address,
            ethers.parseEther('1000000'),
            true,
        );
    }

    /**
     * Deploy fresh mocks + verifier + gateway. If `approveVersion` is true,
     * the verifier version is approved on the gateway (default). If false,
     * no version is approved (for testing M-1 whitelist rejection).
     */
    async function deployFresh(trustedKeyAddr, approveVersion = true) {
        const signers = await ethers.getSigners();
        const o = signers[0];
        const g = signers[1];
        const c = signers[2];

        const mb = await (
            await ethers.getContractFactory('MockBootstrapForAttestation')
        ).deploy();
        await mb.waitForDeployment();
        const mc = await (
            await ethers.getContractFactory('MockOmniCoreForAttestation')
        ).deploy();
        await mc.waitForDeployment();
        const mr = await (
            await ethers.getContractFactory(
                'MockOmniRegistrationForAttestation',
            )
        ).deploy();
        await mr.waitForDeployment();

        const v = await (
            await ethers.getContractFactory('RandomCommitteeVerifier')
        ).deploy(
            o.address,
            await mb.getAddress(),
            await mc.getAddress(),
            await mr.getAddress(),
            INITIAL_N,
            INITIAL_M,
            3,
            ethers.parseEther('1000000'),
        );
        await v.waitForDeployment();

        const vals = [];
        for (let i = 0; i < 15; i++) {
            const w = ethers.Wallet.createRandom();
            vals.push(w);
            await mb.setNodeActive(w.address, true, 0);
            await mr.setKycTier(w.address, 3);
            await mc.setStake(w.address, ethers.parseEther('1000000'), true);
        }
        await v.refreshEligibleSet();

        const gw = await (
            await ethers.getContractFactory('OmniAttestationGateway')
        ).deploy(
            o.address,
            g.address,
            trustedKeyAddr || ethers.ZeroAddress,
        );
        await gw.waitForDeployment();

        if (approveVersion) {
            await gw.setApprovedVerifierVersion(APPROVED_VERSION, true);
        }
        await gw.setAuthorizedConsumer(c.address, true);

        return { gw, v, mb, mc, mr, o, g, c, vals };
    }

    before(async function () {
        const signers = await ethers.getSigners();
        owner = signers[0];
        guardian = signers[1];
        consumer = signers[2];
        outsider = signers[3];
        subject = signers[4];

        trustedKey = ethers.Wallet.createRandom();

        for (let i = 0; i < 15; i++) {
            VALIDATORS.push(ethers.Wallet.createRandom());
        }

        mockBootstrap = await (
            await ethers.getContractFactory('MockBootstrapForAttestation')
        ).deploy();
        await mockBootstrap.waitForDeployment();
        mockOmniCore = await (
            await ethers.getContractFactory('MockOmniCoreForAttestation')
        ).deploy();
        await mockOmniCore.waitForDeployment();
        mockOmniRegistration = await (
            await ethers.getContractFactory(
                'MockOmniRegistrationForAttestation',
            )
        ).deploy();
        await mockOmniRegistration.waitForDeployment();

        for (const w of VALIDATORS) {
            await setEligible(w);
        }

        mockVerifier = await (
            await ethers.getContractFactory('RandomCommitteeVerifier')
        ).deploy(
            owner.address,
            await mockBootstrap.getAddress(),
            await mockOmniCore.getAddress(),
            await mockOmniRegistration.getAddress(),
            INITIAL_N,
            INITIAL_M,
            3,
            ethers.parseEther('1000000'),
        );
        await mockVerifier.waitForDeployment();
        await mockVerifier.refreshEligibleSet();

        gateway = await (
            await ethers.getContractFactory('OmniAttestationGateway')
        ).deploy(owner.address, guardian.address, trustedKey.address);
        await gateway.waitForDeployment();

        await gateway
            .connect(owner)
            .setApprovedVerifierVersion(APPROVED_VERSION, true);
        await gateway
            .connect(owner)
            .setAuthorizedConsumer(consumer.address, true);
    });

    /**
     * Helper: get a future deadline using the chain's block.timestamp.
     */
    async function futureDeadline(offsetSec = 3600) {
        const block = await ethers.provider.getBlock('latest');
        return block.timestamp + offsetSec;
    }

    /**
     * Helper: get a past deadline using the chain's block.timestamp.
     */
    async function pastDeadline(offsetSec = 3600) {
        const block = await ethers.provider.getBlock('latest');
        return block.timestamp - offsetSec;
    }

    // ════════════════════════════════════════════════════════════════════════
    // INV-01: Only authorizedConsumers can call verifyAndConsume
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-01: verifyAndConsume access control', function () {
        it('rejects unauthorized callers (100 random iterations)', async function () {
            for (let i = 0; i < 100; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const deadline = await futureDeadline();
                const proof = signLegacyRaw(trustedKey, digest);

                await expect(
                    gateway
                        .connect(outsider)
                        .verifyAndConsume(
                            subject.address,
                            digest,
                            nonce,
                            deadline,
                            proof,
                        ),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'UnauthorizedConsumer',
                );
            }
        });

        it('accepts authorized consumer calls', async function () {
            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.emit(gateway, 'AttestationAccepted');
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-02: Only owner can call governance setters
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-02: Governance setter access control', function () {
        it('setTrustedVerificationKey: rejects non-owner (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonOwner = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: nonOwner.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway
                        .connect(nonOwner)
                        .setTrustedVerificationKey(randomAddress()),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'OwnableUnauthorizedAccount',
                );
            }
        });

        it('setAuthorizedConsumer: rejects non-owner (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonOwner = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: nonOwner.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway
                        .connect(nonOwner)
                        .setAuthorizedConsumer(randomAddress(), true),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'OwnableUnauthorizedAccount',
                );
            }
        });

        it('setGuardian: rejects non-owner (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonOwner = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: nonOwner.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway.connect(nonOwner).setGuardian(randomAddress()),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'OwnableUnauthorizedAccount',
                );
            }
        });

        it('disableGuardian: rejects non-owner (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonOwner = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: nonOwner.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway.connect(nonOwner).disableGuardian(),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'OwnableUnauthorizedAccount',
                );
            }
        });

        it('disableLegacyPath: rejects non-owner (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonOwner = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: nonOwner.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway.connect(nonOwner).disableLegacyPath(),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'OwnableUnauthorizedAccount',
                );
            }
        });

        it('unpause: rejects non-owner (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonOwner = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: nonOwner.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway.connect(nonOwner).unpause(),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'OwnableUnauthorizedAccount',
                );
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-03: Only guardian or owner can call pause
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-03: Pause access control', function () {
        it('rejects non-guardian, non-owner callers (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const rando = ethers.Wallet.createRandom().connect(
                    ethers.provider,
                );
                await owner.sendTransaction({
                    to: rando.address,
                    value: ethers.parseEther('1'),
                });
                await expect(
                    gateway.connect(rando).pause(),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'UnauthorizedGuardian',
                );
            }
        });

        it('accepts guardian caller', async function () {
            await gateway.connect(guardian).pause();
            await gateway.connect(owner).unpause();
        });

        it('accepts owner caller', async function () {
            await gateway.connect(owner).pause();
            await gateway.connect(owner).unpause();
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-04: Nonce replay protection
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-04: Nonce replay protection', function () {
        it('rejects reused nonce (100 random iterations)', async function () {
            for (let i = 0; i < 100; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const deadline = await futureDeadline();
                const proof = signLegacyRaw(trustedKey, digest);

                await gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    );

                await expect(
                    gateway
                        .connect(consumer)
                        .verifyAndConsume(
                            subject.address,
                            digest,
                            nonce,
                            deadline,
                            proof,
                        ),
                ).to.be.revertedWithCustomError(gateway, 'NonceAlreadyUsed');
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-05: Deadline enforcement
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-05: Deadline enforcement', function () {
        it('rejects expired proofs (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const deadline = await pastDeadline(
                    Number(randomUint256(1n, 3600n)),
                );
                const proof = signLegacyRaw(trustedKey, digest);

                await expect(
                    gateway
                        .connect(consumer)
                        .verifyAndConsume(
                            subject.address,
                            digest,
                            nonce,
                            deadline,
                            proof,
                        ),
                ).to.be.revertedWithCustomError(gateway, 'ProofExpired');
            }
        });

        it('accepts proofs with future deadline', async function () {
            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.emit(gateway, 'AttestationAccepted');
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-06: Pause blocks verifyAndConsume
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-06: Pause blocks verifyAndConsume', function () {
        it('reverts when paused, accepts after unpause', async function () {
            await gateway.connect(owner).pause();

            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.be.revertedWithCustomError(gateway, 'EnforcedPause');

            await gateway.connect(owner).unpause();

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.emit(gateway, 'AttestationAccepted');
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-07: Legacy path correctness
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-07: Legacy path correctness', function () {
        it('rejects invalid legacy signature (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const deadline = await futureDeadline();
                const wrongKey = ethers.Wallet.createRandom();
                const proof = signLegacyRaw(wrongKey, digest);

                await expect(
                    gateway
                        .connect(consumer)
                        .verifyAndConsume(
                            subject.address,
                            digest,
                            nonce,
                            deadline,
                            proof,
                        ),
                ).to.be.revertedWithCustomError(
                    gateway,
                    'InvalidVerificationProof',
                );
            }
        });

        it('accepts valid legacy signature', async function () {
            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.emit(gateway, 'AttestationAccepted');
        });

        it('reverts when trustedVerificationKey is zero', async function () {
            const { gw } = await deployFresh(ethers.ZeroAddress);

            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gw.connect(consumer).verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    deadline,
                    proof,
                ),
            ).to.be.revertedWithCustomError(
                gw,
                'TrustedVerificationKeyNotSet',
            );
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-08: Committee path correctness
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-08: Committee path correctness', function () {
        let gw;
        let v;
        let vals;

        before(async function () {
            const fresh = await deployFresh(trustedKey.address);
            gw = fresh.gw;
            v = fresh.v;
            vals = fresh.vals;
            await gw.connect(owner).setCommitteeVerifier(await v.getAddress());
        });

        /**
         * Find which validators are in the committee for a given
         * (digest, commitBlock) pair by querying the verifier.
         */
        async function findCommittee(digest, commitBlock) {
            const committee = await v.committeeFor(digest, commitBlock);
            const lowerSet = new Set(
                committee.map((a) => a.toLowerCase()),
            );
            return vals.filter((w) =>
                lowerSet.has(w.address.toLowerCase()),
            );
        }

        it('rejects invalid committee proof (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const deadline = await futureDeadline();
                const garbageProof = concat([
                    ethers.zeroPadValue(ethers.toBeHex(1), 32),
                    randomBytes(65 * INITIAL_M),
                ]);

                await expect(
                    gw.connect(consumer).verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        garbageProof,
                    ),
                ).to.be.revertedWithCustomError(
                    gw,
                    'InvalidVerificationProof',
                );
            }
        });

        it('rejects when subject is in committee', async function () {
            const digest = randomBytes32();
            const nonce = randomBytes32();
            const deadline = await futureDeadline();

            const commitBlock = await confirmedCommitBlock();
            const committee = await findCommittee(digest, commitBlock);
            const subjectInCommittee = committee[0];
            const proof = buildCommitteeProof(
                commitBlock,
                committee.slice(0, INITIAL_M),
                digest,
            );

            await expect(
                gw.connect(consumer).verifyAndConsume(
                    subjectInCommittee.address,
                    digest,
                    nonce,
                    deadline,
                    proof,
                ),
            ).to.be.revertedWithCustomError(gw, 'SubjectInCommittee');
        });

        it('accepts valid committee proof', async function () {
            const digest = randomBytes32();
            const nonce = randomBytes32();
            const deadline = await futureDeadline();

            const commitBlock = await confirmedCommitBlock();
            const committee = await findCommittee(digest, commitBlock);
            const proof = buildCommitteeProof(
                commitBlock,
                committee.slice(0, INITIAL_M),
                digest,
            );

            await expect(
                gw.connect(consumer).verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    deadline,
                    proof,
                ),
            )
                .to.emit(gw, 'AttestationAccepted')
                .and.to.emit(gw, 'CommitteeAttested');
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-09: legacyDisabled latch
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-09: legacyDisabled latch', function () {
        let gw;

        before(async function () {
            const fresh = await deployFresh(trustedKey.address);
            gw = fresh.gw;
        });

        it('blocks legacy path after disableLegacyPath', async function () {
            await gw.connect(owner).disableLegacyPath();

            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gw.connect(consumer).verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    deadline,
                    proof,
                ),
            ).to.be.revertedWithCustomError(
                gw,
                'LegacyPathPermanentlyDisabled',
            );

            expect(await gw.legacyDisabled()).to.equal(true);
        });

        it('legacyDisabled is irreversible', async function () {
            await gw.connect(owner).disableLegacyPath();
            expect(await gw.legacyDisabled()).to.equal(true);
            await gw.connect(owner).disableLegacyPath();
            expect(await gw.legacyDisabled()).to.equal(true);
        });

        it('committee path still works after legacyDisabled', async function () {
            const vAddr = await mockVerifier.getAddress();
            await gw
                .connect(owner)
                .setApprovedVerifierVersion(APPROVED_VERSION, true);
            await gw.connect(owner).setCommitteeVerifier(vAddr);

            const digest = randomBytes32();
            const nonce = randomBytes32();
            const deadline = await futureDeadline();

            const commitBlock = await confirmedCommitBlock();
            const committee = await mockVerifier.committeeFor(
                digest,
                commitBlock,
            );
            const lowerSet = new Set(
                committee.map((a) => a.toLowerCase()),
            );
            const matched = VALIDATORS.filter((w) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            const proof = buildCommitteeProof(
                commitBlock,
                matched.slice(0, INITIAL_M),
                digest,
            );

            await expect(
                gw.connect(consumer).verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    deadline,
                    proof,
                ),
            ).to.emit(gw, 'AttestationAccepted');
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-10: Nonce consumption permanence
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-10: Nonce consumption permanence', function () {
        it('usedNonces is true after successful verifyAndConsume (50 random iterations)', async function () {
            for (let i = 0; i < 50; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const deadline = await futureDeadline();
                const proof = signLegacyRaw(trustedKey, digest);

                await gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    );

                expect(await gateway.usedNonces(nonce)).to.equal(true);
            }
        });

        it('usedNonces is false for never-used nonce', async function () {
            const freshNonce = randomBytes32();
            expect(await gateway.usedNonces(freshNonce)).to.equal(false);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-11: Event emission correctness
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-11: Event emission correctness', function () {
        it('emits AttestationAccepted with committeePath=false for legacy path', async function () {
            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const proof = signLegacyRaw(trustedKey, digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            )
                .to.emit(gateway, 'AttestationAccepted')
                .withArgs(subject.address, digest, false);
        });

        it('emits AttestationAccepted + CommitteeAttested for committee path', async function () {
            const { gw, v, vals } = await deployFresh(trustedKey.address);
            await gw.connect(owner).setCommitteeVerifier(await v.getAddress());

            const digest = randomBytes32();
            const nonce = randomBytes32();
            const deadline = await futureDeadline();

            const commitBlock = await confirmedCommitBlock();
            const committee = await v.committeeFor(digest, commitBlock);
            const lowerSet = new Set(
                committee.map((a) => a.toLowerCase()),
            );
            const matched = vals.filter((w) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            const proof = buildCommitteeProof(
                commitBlock,
                matched.slice(0, INITIAL_M),
                digest,
            );

            const tx = await gw.connect(consumer).verifyAndConsume(
                subject.address,
                digest,
                nonce,
                deadline,
                proof,
            );
            const receipt = await tx.wait();

            const iface = gw.interface;
            const acceptedEvents = receipt.logs.filter((log) => {
                try {
                    const parsed = iface.parseLog({
                        topics: [...log.topics],
                        data: log.data,
                    });
                    return parsed.name === 'AttestationAccepted';
                } catch {
                    return false;
                }
            });
            expect(acceptedEvents.length).to.equal(1);
            const parsedAccepted = iface.parseLog({
                topics: [...acceptedEvents[0].topics],
                data: acceptedEvents[0].data,
            });
            expect(parsedAccepted.args.committeePath).to.equal(true);

            const committeeEvents = receipt.logs.filter((log) => {
                try {
                    const parsed = iface.parseLog({
                        topics: [...log.topics],
                        data: log.data,
                    });
                    return parsed.name === 'CommitteeAttested';
                } catch {
                    return false;
                }
            });
            expect(committeeEvents.length).to.equal(1);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-12: Verifier version whitelist enforcement
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-12: Verifier version whitelist', function () {
        it('rejects verifier with unapproved version', async function () {
            const { gw, v } = await deployFresh(trustedKey.address, false);

            await expect(
                gw.connect(owner).setCommitteeVerifier(await v.getAddress()),
            ).to.be.revertedWithCustomError(
                gw,
                'VerifierVersionNotApproved',
            );
        });

        it('accepts verifier with approved version', async function () {
            await gateway
                .connect(owner)
                .setCommitteeVerifier(await mockVerifier.getAddress());
            await gateway.connect(owner).clearCommitteeVerifier();
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-13: Pool-size brick-prevention gate
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-13: Pool-size brick-prevention', function () {
        it('rejects verifier when pool < committeeSize', async function () {
            // Deploy fresh mocks with only 4 eligible validators.
            const signers = await ethers.getSigners();
            const o = signers[0];
            const g = signers[1];
            const c = signers[2];

            const mb = await (
                await ethers.getContractFactory('MockBootstrapForAttestation')
            ).deploy();
            await mb.waitForDeployment();
            const mc = await (
                await ethers.getContractFactory('MockOmniCoreForAttestation')
            ).deploy();
            await mc.waitForDeployment();
            const mr = await (
                await ethers.getContractFactory(
                    'MockOmniRegistrationForAttestation',
                )
            ).deploy();
            await mr.waitForDeployment();

            // Only 4 validators eligible — pool=4 < N=15.
            for (let i = 0; i < 4; i++) {
                const w = ethers.Wallet.createRandom();
                await mb.setNodeActive(w.address, true, 0);
                await mr.setKycTier(w.address, 3);
                await mc.setStake(
                    w.address,
                    ethers.parseEther('1000000'),
                    true,
                );
            }

            const bigV = await (
                await ethers.getContractFactory('RandomCommitteeVerifier')
            ).deploy(
                o.address,
                await mb.getAddress(),
                await mc.getAddress(),
                await mr.getAddress(),
                15, // N=15
                10, // M=10
                3,
                ethers.parseEther('1000000'),
            );
            await bigV.waitForDeployment();
            await bigV.refreshEligibleSet();

            const gw = await (
                await ethers.getContractFactory('OmniAttestationGateway')
            ).deploy(o.address, g.address, trustedKey.address);
            await gw.waitForDeployment();
            await gw
                .connect(o)
                .setApprovedVerifierVersion(APPROVED_VERSION, true);

            await expect(
                gw.connect(o).setCommitteeVerifier(await bigV.getAddress()),
            ).to.be.revertedWithCustomError(gw, 'EligiblePoolTooSmall');
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-14: Zero-address guards on setters
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-14: Zero-address guards', function () {
        it('setCommitteeVerifier rejects address(0)', async function () {
            await expect(
                gateway
                    .connect(owner)
                    .setCommitteeVerifier(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(gateway, 'ZeroAddress');
        });

        it('setAuthorizedConsumer rejects address(0)', async function () {
            await expect(
                gateway
                    .connect(owner)
                    .setAuthorizedConsumer(ethers.ZeroAddress, true),
            ).to.be.revertedWithCustomError(gateway, 'ZeroAddress');
        });

        it('setGuardian rejects address(0)', async function () {
            await expect(
                gateway.connect(owner).setGuardian(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(gateway, 'ZeroAddress');
        });

        it('disableGuardian sets guardian to address(0) (explicit, intentional)', async function () {
            await gateway.connect(owner).disableGuardian();
            expect(await gateway.guardian()).to.equal(ethers.ZeroAddress);
            await gateway.connect(owner).setGuardian(guardian.address);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-15: Empty version string rejection
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-15: Empty version string rejection', function () {
        it('rejects empty version string', async function () {
            await expect(
                gateway.connect(owner).setApprovedVerifierVersion('', true),
            ).to.be.revertedWithCustomError(gateway, 'EmptyVersionString');
        });

        it('accepts non-empty version string', async function () {
            await gateway
                .connect(owner)
                .setApprovedVerifierVersion('test-version-v1', true);
            await gateway
                .connect(owner)
                .setApprovedVerifierVersion('test-version-v1', false);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // INV-16: Ownable2Step two-step ownership transfer
    // ════════════════════════════════════════════════════════════════════════
    describe('INV-16: Ownable2Step ownership transfer', function () {
        it('requires two-step transfer (transfer + accept)', async function () {
            const newOwner = ethers.Wallet.createRandom().connect(
                ethers.provider,
            );
            await owner.sendTransaction({
                to: newOwner.address,
                value: ethers.parseEther('1'),
            });

            await gateway.connect(owner).transferOwnership(newOwner.address);
            expect(await gateway.owner()).to.equal(owner.address);

            await gateway.connect(newOwner).acceptOwnership();
            expect(await gateway.owner()).to.equal(newOwner.address);

            await gateway
                .connect(newOwner)
                .transferOwnership(owner.address);
            await gateway.connect(owner).acceptOwnership();
            expect(await gateway.owner()).to.equal(owner.address);
        });

        it('rejects direct ownership transfer without accept', async function () {
            const rando = ethers.Wallet.createRandom().connect(
                ethers.provider,
            );
            await owner.sendTransaction({
                to: rando.address,
                value: ethers.parseEther('1'),
            });

            await expect(
                gateway.connect(rando).acceptOwnership(),
            ).to.be.revertedWithCustomError(
                gateway,
                'OwnableUnauthorizedAccount',
            );
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // Edge-case fuzzing
    // ════════════════════════════════════════════════════════════════════════
    describe('Edge-case fuzzing', function () {
        it('handles random nonce + digest + deadline combinations (200 iterations)', async function () {
            for (let i = 0; i < 200; i++) {
                const nonce = randomBytes32();
                const digest = randomBytes32();
                const future = Math.random() > 0.5;
                const deadline = future
                    ? await futureDeadline(
                          Number(randomUint256(1n, 7200n)),
                      )
                    : await pastDeadline(
                          Number(randomUint256(1n, 3600n)),
                      );
                const proof = signLegacyRaw(trustedKey, digest);

                if (future) {
                    await gateway
                        .connect(consumer)
                        .verifyAndConsume(
                            subject.address,
                            digest,
                            nonce,
                            deadline,
                            proof,
                        );
                    expect(await gateway.usedNonces(nonce)).to.equal(true);
                } else {
                    await expect(
                        gateway
                            .connect(consumer)
                            .verifyAndConsume(
                                subject.address,
                                digest,
                                nonce,
                                deadline,
                                proof,
                            ),
                    ).to.be.revertedWithCustomError(gateway, 'ProofExpired');
                    expect(await gateway.usedNonces(nonce)).to.equal(false);
                }
            }
        });

        it('nonce not consumed on failed verification', async function () {
            const nonce = randomBytes32();
            const digest = randomBytes32();
            const deadline = await futureDeadline();
            const wrongKey = ethers.Wallet.createRandom();
            const proof = signLegacyRaw(wrongKey, digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.be.revertedWithCustomError(
                gateway,
                'InvalidVerificationProof',
            );

            expect(await gateway.usedNonces(nonce)).to.equal(false);

            const validProof = signLegacyRaw(trustedKey, digest);
            await gateway
                .connect(consumer)
                .verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    deadline,
                    validProof,
                );
            expect(await gateway.usedNonces(nonce)).to.equal(true);
        });

        it('isAcceptable returns correct values for various states', async function () {
            const nonce = randomBytes32();
            const futureDl = await futureDeadline();
            const pastDl = await pastDeadline();

            expect(await gateway.isAcceptable(nonce, futureDl)).to.equal(true);
            expect(await gateway.isAcceptable(nonce, pastDl)).to.equal(false);

            const digest = randomBytes32();
            const proof = signLegacyRaw(trustedKey, digest);
            await gateway
                .connect(consumer)
                .verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    futureDl,
                    proof,
                );

            expect(await gateway.isAcceptable(nonce, futureDl)).to.equal(false);

            await gateway.connect(owner).pause();
            const freshNonce = randomBytes32();
            expect(
                await gateway.isAcceptable(freshNonce, futureDl),
            ).to.equal(false);
            await gateway.connect(owner).unpause();
        });
    });
});
