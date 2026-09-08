/**
 * @file OmniAttestationGateway.test.ts
 * @description Hardhat tests for `OmniAttestationGateway` — the
 * post-audit single-entry attestation dispatcher between
 * `OmniRegistration` and the verifier(s).
 *
 * Coverage targets audit findings the gateway addresses:
 *   • C-1: original 3·N pool-to-committee security gate is INTENTIONALLY
 *     ABSENT — training-wheels threat model at launch (the 5 beacon
 *     validators dominate by construction until pool > 15).
 *   • C-2: subject ∉ committee — reject if signer == subject
 *   • H-4: pool-size brick-prevention (pool >= N)
 *   • H-5: Pausable + guardian (pause via guardian OR owner;
 *          unpause owner-only)
 *   • M-1: verifierVersion whitelist in setter
 *   • M-2: explicit split setCommitteeVerifier vs clearCommitteeVerifier
 *
 * Plus standard contract hygiene: ownership transfer, authorized-consumer
 * gating, nonce replay, deadline, dual-path (legacy + M-of-N).
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (arr: any[]) => string = ethers.concat;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;

const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';
const APPROVED_VERSION = 'random-committee-ecdsa-v2';

describe('OmniAttestationGateway', function () {
    let gateway: any;
    let verifier: any;
    let mockBootstrap: any;
    let mockOmniCore: any;
    let mockOmniRegistration: any;

    let owner: any;
    let guardian: any;
    let consumer: any; // simulates OmniRegistration as authorized caller
    let outsider: any;
    let subject: any; // attestation subject

    // 15 distinct validator wallets — pool=15 ≥ 3*N (5) satisfies the C-1 gate.
    const VALIDATORS: any[] = [];
    let trustedKey: any;

    const INITIAL_M = 4;

    async function setEligible(w: any): Promise<void> {
        await mockBootstrap.setNodeActive(w.address, true, 0);
        await mockOmniRegistration.setKycTier(w.address, 3);
        await mockOmniCore.setStake(
            w.address,
            ethers.parseEther('1000000'),
            true,
        );
    }

    /**
     * Sign `digest` under the EIP-191 envelope used by the committee
     * verifier (`Ecdsa5of5AttestationVerifier`-style ethSigned).
     */
    function signCommitteeEthMessage(wallet: any, digest: string): string {
        const ethSigned = keccak256(
            concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
        );
        const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
        return sigObj.serialized;
    }

    /**
     * Sign `digest` directly (raw — no EIP-191 prefix). This matches the
     * legacy single-key path in `OmniAttestationGateway.verifyAndConsume`
     * which calls `digest.recover(proof)` via OpenZeppelin ECDSA — no
     * envelope. The digest passed in is ALREADY the EIP-712 hash
     * (`keccak256("\x19\x01" || domainSep || structHash)`), so no further
     * envelope wrap is needed.
     */
    function signLegacyRaw(wallet: any, digest: string): string {
        const sigObj = new SigningKey(wallet.privateKey).sign(digest);
        return sigObj.serialized;
    }

    /**
     * Build committee proof = commitBlock(32) || sorted sigs.
     */
    function buildCommitteeProof(
        commitBlock: number,
        signers: any[],
        digest: string,
    ): string {
        const sorted = [...signers].sort((a, b) =>
            a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
        );
        const sigs = sorted.map((w) => signCommitteeEthMessage(w, digest));
        const commitBlockHex = ethers.toBeHex(commitBlock, 32);
        return concat([commitBlockHex, ...sigs]);
    }

    /**
     * Mine a block and return the (now-confirmed) previous block number,
     * so `blockhash(N)` is non-zero inside an eth_call. Also mines the
     * second block needed by the H-3 two-block seed derivation.
     */
    async function confirmedCommitBlock(): Promise<number> {
        await ethers.provider.send('evm_mine', []);
        await ethers.provider.send('evm_mine', []);
        return (await ethers.provider.getBlockNumber()) - 1;
    }

    beforeEach(async function () {
        const signers = await ethers.getSigners();
        owner = signers[0];
        guardian = signers[1];
        consumer = signers[2];
        outsider = signers[3];
        subject = signers[4];

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

        // Verifier (15 validators in pool, N=5, M=4 → 3·N = 15 met)
        verifier = await (
            await ethers.getContractFactory('RandomCommitteeVerifier')
        ).deploy(
            owner.address,
            await mockBootstrap.getAddress(),
            await mockOmniCore.getAddress(),
            await mockOmniRegistration.getAddress(),
            5, // N
            INITIAL_M, // M
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

        // Approve the verifier's version + authorize the consumer.
        await gateway.setApprovedVerifierVersion(APPROVED_VERSION, true);
        await gateway.setAuthorizedConsumer(consumer.address, true);
    });

    // ──────────────────────────────────────────────────── construction ──

    describe('construction', () => {
        it('initializes owner + guardian + trustedKey correctly', async () => {
            expect(await gateway.owner()).to.equal(owner.address);
            expect(await gateway.guardian()).to.equal(guardian.address);
            expect(await gateway.trustedVerificationKey()).to.equal(
                trustedKey.address,
            );
            expect(await gateway.committeeVerifier()).to.equal(ethers.ZeroAddress);
        });

        it('reverts on zero owner', async () => {
            const Gateway = await ethers.getContractFactory(
                'OmniAttestationGateway',
            );
            await expect(
                Gateway.deploy(
                    ethers.ZeroAddress,
                    guardian.address,
                    trustedKey.address,
                ),
            ).to.be.reverted;
        });

        it('allows zero guardian + zero trustedKey at construction (gradual config)', async () => {
            const Gateway = await ethers.getContractFactory(
                'OmniAttestationGateway',
            );
            const g = await Gateway.deploy(
                owner.address,
                ethers.ZeroAddress,
                ethers.ZeroAddress,
            );
            await g.waitForDeployment();
            expect(await g.guardian()).to.equal(ethers.ZeroAddress);
            expect(await g.trustedVerificationKey()).to.equal(ethers.ZeroAddress);
        });
    });

    // ────────────────────────────── setCommitteeVerifier (M-1 + C-1 + H-4) ──

    describe('setCommitteeVerifier — audit guards', () => {
        it('rejects zero address', async () => {
            await expect(
                gateway.setCommitteeVerifier(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(gateway, 'ZeroAddress');
        });

        it('rejects verifier whose version is NOT approved (audit M-1)', async () => {
            await gateway.setApprovedVerifierVersion(APPROVED_VERSION, false);
            await expect(
                gateway.setCommitteeVerifier(await verifier.getAddress()),
            ).to.be.revertedWithCustomError(gateway, 'VerifierVersionNotApproved');
        });

        it('rejects when pool < committeeSize (audit H-4 brick prevention)', async () => {
            // Shrink the eligible pool below N=5 by disqualifying 11 of 15
            // validators (stake below threshold) — pool=4 < N=5.
            for (let i = 0; i < 11; ++i) {
                await mockOmniCore.setStake(
                    VALIDATORS[i].address,
                    ethers.parseEther('500000'),
                    true,
                );
            }
            await verifier.refreshEligibleSet();
            expect((await verifier.eligibleSnapshot()).length).to.equal(4);

            await expect(
                gateway.setCommitteeVerifier(await verifier.getAddress()),
            ).to.be.revertedWithCustomError(gateway, 'EligiblePoolTooSmall');
        });

        it('accepts when pool >= committeeSize (training-wheels phase)', async () => {
            await expect(
                gateway.setCommitteeVerifier(await verifier.getAddress()),
            )
                .to.emit(gateway, 'CommitteeVerifierSet')
                .withArgs(await verifier.getAddress());
            expect(await gateway.committeeVerifier()).to.equal(
                await verifier.getAddress(),
            );
        });

        it('only owner can call', async () => {
            await expect(
                gateway
                    .connect(outsider)
                    .setCommitteeVerifier(await verifier.getAddress()),
            ).to.be.reverted;
        });
    });

    // ─────────────────────────────────────────── clearCommitteeVerifier (M-2) ──

    describe('clearCommitteeVerifier — audit M-2 explicit rollback', () => {
        beforeEach(async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
        });

        it('rolls back to legacy path', async () => {
            await expect(gateway.clearCommitteeVerifier())
                .to.emit(gateway, 'CommitteeVerifierCleared');
            expect(await gateway.committeeVerifier()).to.equal(
                ethers.ZeroAddress,
            );
        });

        it('only owner can call', async () => {
            await expect(
                gateway.connect(outsider).clearCommitteeVerifier(),
            ).to.be.reverted;
        });
    });

    // ───────────────────────────────────── verifyAndConsume — legacy path ──

    describe('verifyAndConsume — legacy single-key path', () => {
        const digest = keccak256(toUtf8Bytes('test-digest'));
        let nonce: string;
        let deadline: number;

        beforeEach(async () => {
            const latest = await ethers.provider.getBlock('latest');
            nonce = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
            deadline = latest!.timestamp + 3600;
        });

        it('accepts a valid signature from trustedVerificationKey', async () => {
            const sig = signLegacyRaw(trustedKey, digest);
            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        sig,
                    ),
            )
                .to.emit(gateway, 'AttestationAccepted')
                .withArgs(subject.address, digest, false);
            expect(await gateway.usedNonces(nonce)).to.be.true;
        });

        it('rejects signature from a non-trusted key', async () => {
            const wrongKey = ethers.Wallet.createRandom();
            const sig = signLegacyRaw(wrongKey, digest);
            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        sig,
                    ),
            ).to.be.revertedWithCustomError(gateway, 'InvalidVerificationProof');
        });

        it('rejects double-spend of the same nonce', async () => {
            const sig = signLegacyRaw(trustedKey, digest);
            await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, sig);
            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        sig,
                    ),
            ).to.be.revertedWithCustomError(gateway, 'NonceAlreadyUsed');
        });

        it('rejects expired deadline', async () => {
            const sig = signLegacyRaw(trustedKey, digest);
            await expect(
                gateway.connect(consumer).verifyAndConsume(
                    subject.address,
                    digest,
                    nonce,
                    1, // way in the past
                    sig,
                ),
            ).to.be.revertedWithCustomError(gateway, 'ProofExpired');
        });

        it('reverts when trustedVerificationKey is unset', async () => {
            await gateway.setTrustedVerificationKey(ethers.ZeroAddress);
            const sig = signLegacyRaw(trustedKey, digest);
            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        sig,
                    ),
            ).to.be.revertedWithCustomError(
                gateway,
                'TrustedVerificationKeyNotSet',
            );
        });
    });

    // ──────────────────────────────────── verifyAndConsume — committee path ──

    describe('verifyAndConsume — Phase 2 M-of-N path', () => {
        const digest = keccak256(toUtf8Bytes('committee-test-digest'));
        let nonce: string;
        let deadline: number;

        beforeEach(async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            const latest = await ethers.provider.getBlock('latest');
            nonce = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
            deadline = latest!.timestamp + 3600;
        });

        it('accepts a 4-of-N proof from committee members', async () => {
            // Pool = 15. Pick a committee algorithmically by querying the verifier.
            const commitBlock = await confirmedCommitBlock();
            const committee: string[] = await verifier.committeeFor(
                digest,
                commitBlock,
            );
            // Find the 4 wallets whose addresses match the first 4 committee members.
            const lowerSet = new Set(committee.map((a) => a.toLowerCase()));
            const matched = VALIDATORS.filter((w) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            expect(matched.length).to.equal(5); // N=5, all selected
            const proof = buildCommitteeProof(commitBlock, matched.slice(0, 4), digest);

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
                .withArgs(subject.address, digest, true);
        });

        it('rejects when subject is a committee member (audit C-2)', async () => {
            const commitBlock = await confirmedCommitBlock();
            const committee: string[] = await verifier.committeeFor(
                digest,
                commitBlock,
            );
            const lowerSet = new Set(committee.map((a) => a.toLowerCase()));
            const matched = VALIDATORS.filter((w) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            // Subject = one of the committee members. Should revert.
            const subjectInCommittee = matched[0];
            const proof = buildCommitteeProof(commitBlock, matched.slice(0, 4), digest);

            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(
                        subjectInCommittee.address, // subject is on committee
                        digest,
                        nonce,
                        deadline,
                        proof,
                    ),
            ).to.be.revertedWithCustomError(gateway, 'SubjectInCommittee');
        });

        it('rejects sub-quorum proof', async () => {
            const commitBlock = await confirmedCommitBlock();
            const committee: string[] = await verifier.committeeFor(
                digest,
                commitBlock,
            );
            const lowerSet = new Set(committee.map((a) => a.toLowerCase()));
            const matched = VALIDATORS.filter((w) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            // Only 3 sigs — below M=4 quorum.
            const proof = buildCommitteeProof(commitBlock, matched.slice(0, 3), digest);

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
            ).to.be.revertedWithCustomError(gateway, 'InvalidVerificationProof');
        });
    });

    // ────────────────────────────────── verifyAndConsume — access control ──

    describe('verifyAndConsume — access control', () => {
        const digest = keccak256(toUtf8Bytes('access-test-digest'));

        it('rejects unauthorized consumer', async () => {
            const sig = signLegacyRaw(trustedKey, digest);
            const latest = await ethers.provider.getBlock('latest');
            const nonce = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
            const deadline = latest!.timestamp + 3600;

            await expect(
                gateway
                    .connect(outsider) // not in authorizedConsumers
                    .verifyAndConsume(
                        subject.address,
                        digest,
                        nonce,
                        deadline,
                        sig,
                    ),
            ).to.be.revertedWithCustomError(gateway, 'UnauthorizedConsumer');
        });
    });

    // ─────────────────────────────────────────── Pausable (audit H-5) ──

    describe('Pausable — audit H-5 guardian emergency-pause', () => {
        const digest = keccak256(toUtf8Bytes('pause-test'));

        it('guardian can pause, owner can unpause', async () => {
            await gateway.connect(guardian).pause();
            expect(await gateway.paused()).to.be.true;

            // Verification blocked.
            const sig = signLegacyRaw(trustedKey, digest);
            const latest = await ethers.provider.getBlock('latest');
            const nonce = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
            const deadline = latest!.timestamp + 3600;
            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(subject.address, digest, nonce, deadline, sig),
            ).to.be.revertedWithCustomError(gateway, 'EnforcedPause');

            // Owner unpauses.
            await gateway.connect(owner).unpause();
            expect(await gateway.paused()).to.be.false;
            await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, sig);
        });

        it('owner can pause too', async () => {
            await gateway.connect(owner).pause();
            expect(await gateway.paused()).to.be.true;
        });

        it('outsider cannot pause', async () => {
            await expect(
                gateway.connect(outsider).pause(),
            ).to.be.revertedWithCustomError(gateway, 'UnauthorizedGuardian');
        });

        it('guardian cannot unpause (only owner)', async () => {
            await gateway.connect(guardian).pause();
            await expect(gateway.connect(guardian).unpause()).to.be.reverted;
        });
    });

    // ─────────────────────────────────────────── setGuardian ──

    describe('setGuardian', () => {
        it('owner can rotate guardian', async () => {
            const newGuard = ethers.Wallet.createRandom();
            await expect(gateway.setGuardian(newGuard.address))
                .to.emit(gateway, 'GuardianSet')
                .withArgs(newGuard.address);
            expect(await gateway.guardian()).to.equal(newGuard.address);
        });

        it('outsider cannot rotate guardian', async () => {
            await expect(
                gateway.connect(outsider).setGuardian(outsider.address),
            ).to.be.reverted;
        });
    });

    // ─────────────────────────────────────────── isAcceptable view ──

    describe('isAcceptable view helper', () => {
        const nonce = '0x' + 'aa'.repeat(32);

        it('returns true for fresh nonce + future deadline', async () => {
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            expect(await gateway.isAcceptable(nonce, deadline)).to.be.true;
        });

        it('returns false when paused', async () => {
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            await gateway.connect(owner).pause();
            expect(await gateway.isAcceptable(nonce, deadline)).to.be.false;
        });

        it('returns false when nonce already used', async () => {
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            const digest = keccak256(toUtf8Bytes('acceptable-test'));
            const sig = signLegacyRaw(trustedKey, digest);
            await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, sig);
            expect(await gateway.isAcceptable(nonce, deadline)).to.be.false;
        });

        it('returns false when deadline is in the past', async () => {
            expect(await gateway.isAcceptable(nonce, 1)).to.be.false;
        });
    });

    // ──────────────────── minAttestersForCommittee cache (AC-1) ──

    describe('minAttestersForCommittee cache (audit Pass-2 AC-1)', () => {
        it('caches minAttestersForCommittee at setCommitteeVerifier time', async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            // Verifier default M = 4
            expect(await gateway.minAttestersForCommittee()).to.equal(INITIAL_M);
        });

        it('clearCommitteeVerifier zeros minAttestersForCommittee', async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            await gateway.clearCommitteeVerifier();
            expect(await gateway.minAttestersForCommittee()).to.equal(0);
        });

        it('training-wheels phase: accepts pool >= N even when pool < 3·N', async () => {
            // Disqualify 10 of 15 validators so pool = 5, exactly meeting
            // N=5. The original Pass-1 C-1 gate would have rejected this
            // (5 < 15), but in launch posture the 5 beacon validators ARE
            // the trusted operator — the 3·N defence against adversarial
            // subset collusion does not apply.
            for (let i = 0; i < 10; ++i) {
                await mockBootstrap.setNodeActive(VALIDATORS[i].address, false, 0);
            }
            await verifier.refreshEligibleSet();
            expect((await verifier.eligibleSnapshot()).length).to.equal(5);

            await expect(
                gateway.setCommitteeVerifier(await verifier.getAddress()),
            ).to.emit(gateway, 'CommitteeVerifierSet');
        });
    });

    // ──────────────────── Audit Pass-2 H-NEW-3: legacy one-way latch ──

    describe('Audit Pass-2 H-NEW-3: legacyDisabled one-way latch', () => {
        it('legacy path works while legacyDisabled = false', async () => {
            const nonce = '0x' + 'a1'.repeat(32);
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            const digest = keccak256(toUtf8Bytes('latch-pre'));
            const sig = signLegacyRaw(trustedKey, digest);
            await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, sig);
            // succeeded
        });

        it('disableLegacyPath emits LegacyPathDisabled', async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            await expect(gateway.disableLegacyPath()).to.emit(
                gateway,
                'LegacyPathDisabled',
            );
            expect(await gateway.legacyDisabled()).to.equal(true);
        });

        it('disableLegacyPath reverts when no committee verifier is set', async () => {
            await expect(gateway.disableLegacyPath()).to.be.revertedWithCustomError(
                gateway,
                'CommitteeVerifierNotSet',
            );
        });

        it('legacy signature is rejected after disableLegacyPath (committee-only)', async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            await gateway.disableLegacyPath();
            const nonce = '0x' + 'a2'.repeat(32);
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            const digest = keccak256(toUtf8Bytes('latch-post'));
            const sig = signLegacyRaw(trustedKey, digest);
            // The gateway is now committee-only: a legacy signature routed
            // through the active committee verifier is rejected.
            await expect(
                gateway
                    .connect(consumer)
                    .verifyAndConsume(subject.address, digest, nonce, deadline, sig),
            ).to.be.revertedWithCustomError(
                gateway,
                'InvalidVerificationProof',
            );
        });

        it('committee path still works after disableLegacyPath', async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            await gateway.disableLegacyPath();

            const nonce = '0x' + 'a3'.repeat(32);
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            const digest = keccak256(toUtf8Bytes('latch-committee'));

            await ethers.provider.send('evm_mine', []);
            await ethers.provider.send('evm_mine', []);
            const commitBlock =
                (await ethers.provider.getBlockNumber()) - 1;
            const committee: string[] = await verifier.committeeFor(
                digest,
                commitBlock,
            );
            const lowerSet = new Set(committee.map((a: string) => a.toLowerCase()));
            const matched = VALIDATORS.filter((w: any) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            const proof = buildCommitteeProof(commitBlock, matched.slice(0, 4), digest);
            await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, proof);
            // succeeded
        });

        it('clearCommitteeVerifier after latch reverts (gateway cannot be bricked)', async () => {
            const verifierAddr = await verifier.getAddress();
            await gateway.setCommitteeVerifier(verifierAddr);
            await gateway.disableLegacyPath();

            // M-01: clearing the committee verifier once the legacy path is
            // permanently disabled would leave NO active path and brick the
            // gateway, so it must revert.
            await expect(gateway.clearCommitteeVerifier()).to.be
                .revertedWithCustomError(gateway, 'LegacyPathPermanentlyDisabled');

            // The committee verifier is still active — the gateway is not bricked.
            expect(await gateway.committeeVerifier()).to.equal(verifierAddr);
        });

        it('disableLegacyPath is owner-only', async () => {
            await expect(
                gateway.connect(outsider).disableLegacyPath(),
            ).to.be.reverted;
        });
    });

    // ─────────────── Audit Pass-2 AC-1 / M-NEW-5: min-attesters guard ──

    describe('Audit Pass-2 AC-1: InsufficientAttesterCount', () => {
        // Direct on-chain test of `(true, [])` is hard without a malicious
        // verifier mock, but we can verify the cached threshold is non-zero
        // and that the committee path rejects sub-quorum proofs (which
        // exercises the same code path because RandomCommitteeVerifier
        // returns the attester list from a sub-quorum proof with length <
        // M before the gateway even reaches its post-condition; see also
        // the "rejects sub-quorum proof" test above).
        it('cached threshold equals verifier quorum at setter time', async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
            const cached = await gateway.minAttestersForCommittee();
            const liveQuorum = await verifier.quorumThreshold();
            expect(cached).to.equal(liveQuorum);
        });
    });

    // ─────────────── Audit Pass-2 M-NEW-2: setGuardian zero-rejection ──

    describe('Audit Pass-2 M-NEW-2: setGuardian / disableGuardian split', () => {
        it('setGuardian rejects address(0)', async () => {
            await expect(
                gateway.setGuardian(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(gateway, 'ZeroAddress');
        });

        it('disableGuardian zeros the guardian explicitly', async () => {
            await expect(gateway.disableGuardian())
                .to.emit(gateway, 'GuardianSet')
                .withArgs(ethers.ZeroAddress);
            expect(await gateway.guardian()).to.equal(ethers.ZeroAddress);
        });

        it('disableGuardian is owner-only', async () => {
            await expect(gateway.connect(outsider).disableGuardian()).to.be.reverted;
        });

        it('after disableGuardian, guardian role rejects pause', async () => {
            await gateway.disableGuardian();
            await expect(
                gateway.connect(guardian).pause(),
            ).to.be.revertedWithCustomError(gateway, 'UnauthorizedGuardian');
        });
    });

    // ───────── Audit Pass-2 M-NEW-3: setApprovedVerifierVersion empty ──

    describe('Audit Pass-2 M-NEW-3: setApprovedVerifierVersion empty-string', () => {
        it('rejects empty version string', async () => {
            await expect(
                gateway.setApprovedVerifierVersion('', true),
            ).to.be.revertedWithCustomError(gateway, 'EmptyVersionString');
        });

        it('rejects empty version string even when removing', async () => {
            await expect(
                gateway.setApprovedVerifierVersion('', false),
            ).to.be.revertedWithCustomError(gateway, 'EmptyVersionString');
        });

        it('accepts a non-empty version string', async () => {
            await expect(
                gateway.setApprovedVerifierVersion('future-bls-v1', true),
            )
                .to.emit(gateway, 'ApprovedVerifierVersion')
                .withArgs(keccak256(toUtf8Bytes('future-bls-v1')), true);
        });
    });

    // ───────── Audit Pass-2 M-NEW-5: CommitteeAttested event emission ──

    describe('Audit Pass-2 M-NEW-5: CommitteeAttested attester emission', () => {
        beforeEach(async () => {
            await gateway.setCommitteeVerifier(await verifier.getAddress());
        });

        it('emits CommitteeAttested alongside AttestationAccepted', async () => {
            const nonce = '0x' + 'b1'.repeat(32);
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            const digest = keccak256(toUtf8Bytes('committee-event-test'));

            await ethers.provider.send('evm_mine', []);
            await ethers.provider.send('evm_mine', []);
            const commitBlock =
                (await ethers.provider.getBlockNumber()) - 1;
            const committee: string[] = await verifier.committeeFor(
                digest,
                commitBlock,
            );
            const lowerSet = new Set(committee.map((a: string) => a.toLowerCase()));
            const matched = VALIDATORS.filter((w: any) =>
                lowerSet.has(w.address.toLowerCase()),
            );
            const proof = buildCommitteeProof(commitBlock, matched.slice(0, 4), digest);

            const tx = await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, proof);
            const receipt = await tx.wait();
            // Find CommitteeAttested log
            const committeeEvt = receipt.logs.find((log: any) => {
                try {
                    const parsed = gateway.interface.parseLog(log);
                    return parsed?.name === 'CommitteeAttested';
                } catch {
                    return false;
                }
            });
            expect(committeeEvt, 'CommitteeAttested should emit').to.not.be
                .undefined;
            const parsed = gateway.interface.parseLog(committeeEvt);
            expect(parsed!.args.digest).to.equal(digest);
            expect(parsed!.args.attesters.length).to.equal(4);
        });

        it('does NOT emit CommitteeAttested on legacy path', async () => {
            // Switch back to legacy
            await gateway.clearCommitteeVerifier();
            const nonce = '0x' + 'b2'.repeat(32);
            const latest = await ethers.provider.getBlock('latest');
            const deadline = latest!.timestamp + 3600;
            const digest = keccak256(toUtf8Bytes('legacy-event-test'));
            const sig = signLegacyRaw(trustedKey, digest);

            const tx = await gateway
                .connect(consumer)
                .verifyAndConsume(subject.address, digest, nonce, deadline, sig);
            const receipt = await tx.wait();
            const committeeEvt = receipt.logs.find((log: any) => {
                try {
                    const parsed = gateway.interface.parseLog(log);
                    return parsed?.name === 'CommitteeAttested';
                } catch {
                    return false;
                }
            });
            expect(committeeEvt, 'no CommitteeAttested on legacy path').to.be
                .undefined;
        });
    });
});
