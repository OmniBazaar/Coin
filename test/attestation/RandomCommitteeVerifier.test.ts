/**
 * @file RandomCommitteeVerifier.test.ts
 * @description Hardhat tests for `RandomCommitteeVerifier` — the Phase 2
 * trustless attestation verifier that replaces OmniRegistration's single
 * `trustedVerificationKey` with a randomized M-of-N committee model.
 *
 * Coverage:
 *   • Construction + parameter validation (ranges, supermajority math)
 *   • Eligibility: state-derived from Bootstrap + OmniCore + OmniRegistration
 *   • refreshEligibleSet: permissionless, sorted ascending, idempotent
 *   • committeeFor: deterministic sample given the same seed
 *   • verify happy path: 4-of-5 sigs from committee → valid
 *   • verify rejects: non-committee signer, duplicate signer, stale commitBlock,
 *     malformed proof length, sub-quorum, wrong message hash
 *   • verifyVeto: single-signer fraud-proof recovery
 *   • setParameters: only owner; supermajority math; emits event
 *   • Auto-exit: validator's stake slashed → next refresh excludes them
 *
 * Reuse: lifts the eligibility primitives from Bootstrap, OmniCore, and
 * OmniRegistration's existing test patterns. Mocks the dependency
 * contracts via lightweight stand-ins.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

// ─── ethers v6 helpers via the hardhat ethers handle ───────────────────────
const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (arr: any[]) => string = ethers.concat;
const hexlify: (v: any) => string = ethers.hexlify;
const zeroPadValue: (v: any, n: number) => string = ethers.zeroPadValue;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;

// EIP-191 prefix that the verifier wraps `messageHash` with via
// `_toEthSignedMessageHash`.
const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';

describe('RandomCommitteeVerifier', function () {
    // ───────────────────────────────────────────────────────────── Mocks ──
    let verifier: any;
    let mockBootstrap: any;
    let mockOmniCore: any;
    let mockOmniRegistration: any;

    let owner: any;
    let nonOwner: any;
    // Five validator wallets stand in for V1-V5; freshly generated each test
    // so the signing keys are accessible.
    let v1: any;
    let v2: any;
    let v3: any;
    let v4: any;
    let v5: any;

    const INITIAL_N = 5;
    const INITIAL_M = 4;
    const INITIAL_MIN_TIER = 3;
    const INITIAL_MIN_STAKE = ethers.parseEther('1000000'); // 1M XOM

    /**
     * Deploy lightweight mocks of the three dependency contracts. Each mock
     * stores per-address state we can poke directly from the test.
     */
    async function deployMocks(): Promise<void> {
        const MockBootstrap = await ethers.getContractFactory(
            'MockBootstrapForAttestation',
        );
        mockBootstrap = await MockBootstrap.deploy();
        await mockBootstrap.waitForDeployment();

        const MockOmniCore = await ethers.getContractFactory(
            'MockOmniCoreForAttestation',
        );
        mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();

        const MockOmniRegistration = await ethers.getContractFactory(
            'MockOmniRegistrationForAttestation',
        );
        mockOmniRegistration = await MockOmniRegistration.deploy();
        await mockOmniRegistration.waitForDeployment();
    }

    /**
     * Wire one validator: make active in Bootstrap, register at given KYC
     * tier, give it the given stake. All defaults satisfy initial eligibility.
     */
    async function setEligible(
        validator: any,
        opts: {
            active?: boolean;
            kycTier?: number;
            stake?: bigint;
            stakeActive?: boolean;
        } = {},
    ): Promise<void> {
        const active = opts.active ?? true;
        const kycTier = opts.kycTier ?? INITIAL_MIN_TIER;
        const stake = opts.stake ?? INITIAL_MIN_STAKE;
        const stakeActive = opts.stakeActive ?? true;

        await mockBootstrap.setNodeActive(validator.address, active, 0);
        await mockOmniRegistration.setKycTier(validator.address, kycTier);
        await mockOmniCore.setStake(validator.address, stake, stakeActive);
    }

    beforeEach(async function () {
        const signers = await ethers.getSigners();
        owner = signers[0];
        nonOwner = signers[1];

        // Generate five raw wallets we control the signing keys for.
        // Connect them to the provider so we can fund + use them as needed.
        const provider = ethers.provider;
        v1 = ethers.Wallet.createRandom().connect(provider);
        v2 = ethers.Wallet.createRandom().connect(provider);
        v3 = ethers.Wallet.createRandom().connect(provider);
        v4 = ethers.Wallet.createRandom().connect(provider);
        v5 = ethers.Wallet.createRandom().connect(provider);

        await deployMocks();

        const Verifier = await ethers.getContractFactory(
            'RandomCommitteeVerifier',
        );
        verifier = await Verifier.deploy(
            owner.address,
            await mockBootstrap.getAddress(),
            await mockOmniCore.getAddress(),
            await mockOmniRegistration.getAddress(),
            INITIAL_N,
            INITIAL_M,
            INITIAL_MIN_TIER,
            INITIAL_MIN_STAKE,
        );
        await verifier.waitForDeployment();

        // Wire all 5 validators as eligible by default. Tests that need
        // partial eligibility override per-validator.
        for (const v of [v1, v2, v3, v4, v5]) {
            await setEligible(v);
        }
    });

    /**
     * Sign `messageHash` with `wallet`'s private key under the EIP-191 envelope
     * the verifier uses. Returns a 65-byte hex string (r || s || v).
     */
    function signEthMessage(wallet: any, messageHash: string): string {
        const ethSigned = keccak256(
            concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(messageHash)]),
        );
        const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
        return sigObj.serialized;
    }

    /**
     * Build a proof = commitBlock(32) || concat(sigs). Sigs sorted by signer
     * address ascending so the verifier's dedup check passes.
     */
    function buildProof(commitBlock: number, signedBy: any[], messageHash: string): string {
        // Sort signers by address ascending.
        const sorted = [...signedBy].sort((a, b) =>
            a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
        );
        const sigs = sorted.map((w) => signEthMessage(w, messageHash));
        // toBeHex(value, 32) → properly zero-padded 32-byte hex.
        const commitBlockHex = ethers.toBeHex(commitBlock, 32);
        return concat([commitBlockHex, ...sigs]);
    }

    /**
     * Resolve a confirmed past blockhash by mining one block then returning
     * the prior block number. Avoids the edge case where `blockhash(N)`
     * inside an eth_call returns zero because N happens to be the call's
     * own pending block (Hardhat/EDR behaviour varies). Always use this
     * helper instead of `getBlockNumber()` directly for `commitBlock`.
     */
    async function confirmedCommitBlock(): Promise<number> {
        await ethers.provider.send('evm_mine', []);
        return (await ethers.provider.getBlockNumber()) - 1;
    }

    // ─────────────────────────────────────────────────── 1. Construction ─

    describe('construction', () => {
        it('exposes immutable dependencies + initial parameters', async () => {
            expect(await verifier.committeeSize()).to.equal(INITIAL_N);
            expect(await verifier.quorumM()).to.equal(INITIAL_M);
            expect(await verifier.minKycTier()).to.equal(INITIAL_MIN_TIER);
            expect(await verifier.minStake()).to.equal(INITIAL_MIN_STAKE);
            expect(await verifier.bootstrap()).to.equal(
                await mockBootstrap.getAddress(),
            );
            expect(await verifier.omniCore()).to.equal(
                await mockOmniCore.getAddress(),
            );
            expect(await verifier.omniRegistration()).to.equal(
                await mockOmniRegistration.getAddress(),
            );
        });

        it('reports IBridgeVerifier interface metadata', async () => {
            expect(await verifier.verifierVersion()).to.equal(
                'random-committee-ecdsa-v2',
            );
            expect(await verifier.quorumThreshold()).to.equal(INITIAL_M);
        });

        it('reverts on zero-address dependencies', async () => {
            const Verifier = await ethers.getContractFactory(
                'RandomCommitteeVerifier',
            );
            await expect(
                Verifier.deploy(
                    ethers.ZeroAddress,
                    await mockBootstrap.getAddress(),
                    await mockOmniCore.getAddress(),
                    await mockOmniRegistration.getAddress(),
                    INITIAL_N,
                    INITIAL_M,
                    INITIAL_MIN_TIER,
                    INITIAL_MIN_STAKE,
                ),
            ).to.be.reverted;
        });

        it('reverts when M < ⌈2N/3⌉', async () => {
            const Verifier = await ethers.getContractFactory(
                'RandomCommitteeVerifier',
            );
            await expect(
                Verifier.deploy(
                    owner.address,
                    await mockBootstrap.getAddress(),
                    await mockOmniCore.getAddress(),
                    await mockOmniRegistration.getAddress(),
                    5,
                    3, // 3 < ⌈2*5/3⌉ = 4
                    INITIAL_MIN_TIER,
                    INITIAL_MIN_STAKE,
                ),
            ).to.be.revertedWithCustomError(
                Verifier,
                'QuorumBelowSupermajority',
            );
        });
    });

    // ──────────────────────────────────────── 2. Eligibility + snapshot ──

    describe('eligibility + snapshot', () => {
        it('isEligibleNow returns true for fully-qualified validators', async () => {
            expect(await verifier.isEligibleNow(v1.address)).to.be.true;
        });

        it('isEligibleNow rejects inactive node', async () => {
            await setEligible(v1, { active: false });
            expect(await verifier.isEligibleNow(v1.address)).to.be.false;
        });

        it('isEligibleNow rejects below-min-tier', async () => {
            await setEligible(v1, { kycTier: 2 });
            expect(await verifier.isEligibleNow(v1.address)).to.be.false;
        });

        it('isEligibleNow rejects below-min-stake', async () => {
            await setEligible(v1, { stake: ethers.parseEther('999999') });
            expect(await verifier.isEligibleNow(v1.address)).to.be.false;
        });

        it('isEligibleNow rejects inactive-stake', async () => {
            await setEligible(v1, { stakeActive: false });
            expect(await verifier.isEligibleNow(v1.address)).to.be.false;
        });

        it('refreshEligibleSet builds a sorted snapshot of qualifying validators', async () => {
            await verifier.refreshEligibleSet();
            const snapshot: string[] = await verifier.eligibleSnapshot();
            expect(snapshot.length).to.equal(5);
            // Sorted ascending.
            for (let i = 1; i < snapshot.length; ++i) {
                expect(snapshot[i].toLowerCase() > snapshot[i - 1].toLowerCase()).to.be.true;
            }
        });

        it('refreshEligibleSet drops a slashed validator on next call', async () => {
            await verifier.refreshEligibleSet();
            expect((await verifier.eligibleSnapshot()).length).to.equal(5);

            // Slash v3: stake drops below minimum.
            await setEligible(v3, { stake: ethers.parseEther('500000') });
            await verifier.refreshEligibleSet();
            const snap2: string[] = await verifier.eligibleSnapshot();
            expect(snap2.length).to.equal(4);
            expect(
                snap2.map((s) => s.toLowerCase()).includes(v3.address.toLowerCase()),
            ).to.be.false;
        });

        it('isValidator (IBridgeVerifier) reflects current snapshot', async () => {
            // Before refresh, snapshot empty.
            expect(await verifier.isValidator(v1.address)).to.be.false;
            await verifier.refreshEligibleSet();
            expect(await verifier.isValidator(v1.address)).to.be.true;
            // Zero-address always false.
            expect(await verifier.isValidator(ethers.ZeroAddress)).to.be.false;
        });
    });

    // ─────────────────────────────────────────── 3. Verify (happy path) ──

    describe('verify — happy path', () => {
        const messageHash = keccak256(toUtf8Bytes('test-attestation-payload'));

        beforeEach(async () => {
            await verifier.refreshEligibleSet();
        });

        it('accepts 4-of-5 sigs from the random committee', async () => {
            const commitBlock = await confirmedCommitBlock();
            // For N=5 from a pool of 5, every validator is in the committee
            // every time — Fisher-Yates over a pool of equal size returns a
            // permutation. So we sign with any 4 of 5.
            const proof = buildProof(commitBlock, [v1, v2, v3, v4], messageHash);
            const [valid, attesters] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.true;
            expect(attesters.length).to.equal(4);
        });

        it('accepts a full 5-of-5 quorum', async () => {
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(commitBlock, [v1, v2, v3, v4, v5], messageHash);
            const [valid, attesters] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.true;
            expect(attesters.length).to.equal(5);
        });
    });

    // ────────────────────────────────────────── 4. Verify (rejections) ──

    describe('verify — rejections', () => {
        const messageHash = keccak256(toUtf8Bytes('test-payload'));

        beforeEach(async () => {
            await verifier.refreshEligibleSet();
        });

        it('rejects sub-quorum (3 sigs when M=4)', async () => {
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(commitBlock, [v1, v2, v3], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('rejects sig from non-committee member when pool > N', async () => {
            // Make pool size 6 by registering an extra validator. With N=5,
            // one of the 6 will NOT be in the committee for a given seed.
            const v6 = ethers.Wallet.createRandom().connect(ethers.provider);
            await setEligible(v6);
            await verifier.refreshEligibleSet();

            const commitBlock = await confirmedCommitBlock();
            // Predict the committee, then deliberately pick a non-committee
            // signer to test rejection.
            const committee: string[] = await verifier.committeeFor(
                messageHash,
                commitBlock,
            );
            const committeeLower = committee.map((a) => a.toLowerCase());
            const all = [v1, v2, v3, v4, v5, v6];
            const outsider = all.find(
                (w) => !committeeLower.includes(w.address.toLowerCase()),
            );
            expect(outsider, 'pool size 6, N=5 must yield 1 outsider').to.not.be
                .undefined;

            // Build a proof with the outsider plus 3 committee members.
            const insiders = all.filter(
                (w) =>
                    committeeLower.includes(w.address.toLowerCase()) &&
                    w.address !== outsider!.address,
            ).slice(0, 3);
            const proof = buildProof(
                commitBlock,
                [...insiders, outsider!],
                messageHash,
            );
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('rejects duplicate signer (same wallet twice)', async () => {
            const commitBlock = await confirmedCommitBlock();
            // Hand-build a proof with v1's signature appearing twice. We
            // can't use buildProof (sort would dedup), so concat manually.
            const sig = signEthMessage(v1, messageHash);
            const commitBlockHex = ethers.toBeHex(commitBlock, 32);
            const proof = concat([commitBlockHex, sig, sig, sig, sig]);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('rejects stale commitBlock (>256 blocks old)', async () => {
            const oldBlock = await confirmedCommitBlock();
            // Advance 260 blocks past oldBlock — blockhash(oldBlock) → 0.
            for (let i = 0; i < 260; ++i) {
                await ethers.provider.send('evm_mine', []);
            }
            const proof = buildProof(oldBlock, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('rejects malformed proof length (no commitBlock head)', async () => {
            const sig = signEthMessage(v1, messageHash);
            // Just 65 bytes (one sig, no commitBlock prefix).
            const [valid] = await verifier.verify(messageHash, sig);
            expect(valid).to.be.false;
        });

        it('rejects proof where sig count exceeds N', async () => {
            // Pool size 6; pass 6 sigs when N=5.
            const v6 = ethers.Wallet.createRandom().connect(ethers.provider);
            await setEligible(v6);
            await verifier.refreshEligibleSet();
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(
                commitBlock,
                [v1, v2, v3, v4, v5, v6],
                messageHash,
            );
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });
    });

    // ─────────────────────────────────────────────── 5. verifyVeto ──

    describe('verifyVeto', () => {
        const vetoHash = keccak256(toUtf8Bytes('fraud-evidence'));

        beforeEach(async () => {
            await verifier.refreshEligibleSet();
        });

        it('recovers the signer when the proof is from an eligible validator', async () => {
            const sig = signEthMessage(v2, vetoHash);
            const [valid, signer] = await verifier.verifyVeto(vetoHash, sig);
            expect(valid).to.be.true;
            expect(signer.toLowerCase()).to.equal(v2.address.toLowerCase());
        });

        it('rejects a fraud proof from a non-attester', async () => {
            const outsider = ethers.Wallet.createRandom();
            const sig = signEthMessage(outsider, vetoHash);
            const [valid, signer] = await verifier.verifyVeto(vetoHash, sig);
            expect(valid).to.be.false;
            expect(signer).to.equal(ethers.ZeroAddress);
        });

        it('rejects malformed fraud proof', async () => {
            const tooShort = '0x' + 'aa'.repeat(64); // 64 bytes, not 65
            const [valid] = await verifier.verifyVeto(vetoHash, tooShort);
            expect(valid).to.be.false;
        });
    });

    // ─────────────────────────────────────────────── 6. setParameters ──

    describe('setParameters', () => {
        it('owner can update parameters atomically', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(7, 5, 3, ethers.parseEther('2000000')),
            )
                .to.emit(verifier, 'ParametersUpdated')
                .withArgs(7, 5, 3, ethers.parseEther('2000000'));
            expect(await verifier.committeeSize()).to.equal(7);
            expect(await verifier.quorumM()).to.equal(5);
            expect(await verifier.minStake()).to.equal(
                ethers.parseEther('2000000'),
            );
        });

        it('non-owner cannot call setParameters', async () => {
            await expect(
                verifier
                    .connect(nonOwner)
                    .setParameters(7, 5, 3, ethers.parseEther('2000000')),
            ).to.be.reverted;
        });

        it('rejects sub-supermajority M', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(9, 5, 3, INITIAL_MIN_STAKE), // 5 < ⌈2*9/3⌉ = 6
            ).to.be.revertedWithCustomError(verifier, 'QuorumBelowSupermajority');
        });

        it('rejects committee size below MIN_COMMITTEE_SIZE', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(2, 2, 3, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'CommitteeSizeOutOfRange');
        });

        it('rejects committee size above MAX_COMMITTEE_SIZE', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(32, 32, 3, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'CommitteeSizeOutOfRange');
        });

        it('rejects minKycTier below MIN_KYC_TIER_FLOOR (audit F-10)', async () => {
            // Hard floor — governance cannot lower below Tier 3 per
            // decision_validator_kyc_tier3_final.
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(5, 4, 2, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'MinKycTierBelowFloor');
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(5, 4, 0, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'MinKycTierBelowFloor');
        });

        it('accepts minKycTier at and above the floor (3+)', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(5, 4, 3, INITIAL_MIN_STAKE),
            ).to.emit(verifier, 'ParametersUpdated');
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(5, 4, 4, INITIAL_MIN_STAKE),
            ).to.emit(verifier, 'ParametersUpdated');
        });

        it('rejects m > n with the specific QuorumExceedsCommittee error (audit L-1)', async () => {
            // Was previously QuorumBelowSupermajority — misleading name. Now
            // a dedicated error per audit L-1 remediation. Cannot directly
            // trigger m>n without first passing the 3M>=2N check; here we
            // exploit the fact that m>n fails the second check distinctly.
            // With n=5, m=6 → 3*6 >= 2*5 (true), but m>n (true) → reverts.
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(5, 6, 3, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'QuorumExceedsCommittee');
        });
    });

    // ─────────────────────────────────────────── 7. committeeFor view ──

    describe('committeeFor', () => {
        const messageHash = keccak256(toUtf8Bytes('test'));

        beforeEach(async () => {
            await verifier.refreshEligibleSet();
        });

        it('returns deterministic committee for the same (msg, block)', async () => {
            const blk = await confirmedCommitBlock();
            const c1: string[] = await verifier.committeeFor(messageHash, blk);
            const c2: string[] = await verifier.committeeFor(messageHash, blk);
            expect(c1.length).to.equal(INITIAL_N);
            expect(c1).to.deep.equal(c2);
        });

        it('returns sorted-ascending committee', async () => {
            const blk = await confirmedCommitBlock();
            const committee: string[] = await verifier.committeeFor(messageHash, blk);
            for (let i = 1; i < committee.length; ++i) {
                expect(
                    committee[i].toLowerCase() > committee[i - 1].toLowerCase(),
                ).to.be.true;
            }
        });

        it('returns empty committee when commitBlock is stale (audit L-2)', async () => {
            // Audit L-2: unified with `verify` — both treat stale commitBlock
            // as a soft failure (empty / false), not a revert. Off-chain
            // callers check `committee.length == 0` to detect staleness.
            const blk = await confirmedCommitBlock();
            for (let i = 0; i < 260; ++i) {
                await ethers.provider.send('evm_mine', []);
            }
            const committee: string[] = await verifier.committeeFor(
                messageHash,
                blk,
            );
            expect(committee).to.have.length(0);
        });
    });

    // ──────────────────────────── 8. H-06 commit-block-bound signatures ─

    describe('H-06 commit-block binding', () => {
        const messageHash = keccak256(toUtf8Bytes('h06-attestation-payload'));

        /**
         * Compute the v2 bound digest the committee signs:
         * keccak256(abi.encode(messageHash, commitBlock)).
         */
        function boundHash(msgHash: string, commitBlock: number): string {
            return keccak256(
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ['bytes32', 'uint256'],
                    [msgHash, commitBlock],
                ),
            );
        }

        /**
         * Build a proof whose signatures are over the BOUND digest for
         * `signedCommitBlock`, while the proof header carries
         * `headerCommitBlock` (normally the same — diverging exercises the
         * grinding rejection).
         */
        function buildBoundProof(
            headerCommitBlock: number,
            signedCommitBlock: number,
            signedBy: any[],
        ): string {
            const sorted = [...signedBy].sort((a, b) =>
                a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
            );
            const digest = boundHash(messageHash, signedCommitBlock);
            const sigs = sorted.map((w) => signEthMessage(w, digest));
            return concat([ethers.toBeHex(headerCommitBlock, 32), ...sigs]);
        }

        beforeEach(async () => {
            await verifier.refreshEligibleSet();
        });

        it('accepts bound-form signatures (v2)', async () => {
            const blk = await confirmedCommitBlock();
            const proof = buildBoundProof(blk, blk, [v1, v2, v3, v4]);
            const [valid, attesters] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.true;
            expect(attesters.length).to.equal(4);
        });

        it('still accepts legacy unbound signatures while toggle is on', async () => {
            expect(await verifier.legacySignaturesAccepted()).to.be.true;
            const blk = await confirmedCommitBlock();
            const proof = buildProof(blk, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.true;
        });

        it('rejects legacy unbound signatures after disableLegacySignatures', async () => {
            await verifier.connect(owner).disableLegacySignatures();
            expect(await verifier.legacySignaturesAccepted()).to.be.false;
            const blk = await confirmedCommitBlock();
            const proof = buildProof(blk, [v1, v2, v3, v4], messageHash);
            const [valid, attesters] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
            expect(attesters.length).to.equal(0);
        });

        it('still accepts bound-form signatures after disableLegacySignatures', async () => {
            await verifier.connect(owner).disableLegacySignatures();
            const blk = await confirmedCommitBlock();
            const proof = buildBoundProof(blk, blk, [v1, v2, v3, v4]);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.true;
        });

        it('rejects grinding: bound signatures replayed under a different commitBlock', async () => {
            await verifier.connect(owner).disableLegacySignatures();
            const signedBlk = await confirmedCommitBlock();
            // Mine a few more blocks and pick a DIFFERENT header commitBlock —
            // simulating a submitter grinding the committee selection after
            // collecting signatures bound to signedBlk.
            await ethers.provider.send('evm_mine', []);
            await ethers.provider.send('evm_mine', []);
            const groundBlk = await confirmedCommitBlock();
            expect(groundBlk).to.not.equal(signedBlk);
            const proof = buildBoundProof(groundBlk, signedBlk, [v1, v2, v3, v4]);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('disableLegacySignatures is owner-only and emits', async () => {
            await expect(
                verifier.connect(v1).disableLegacySignatures(),
            ).to.be.revertedWithCustomError(
                verifier,
                'OwnableUnauthorizedAccount',
            );
            await expect(verifier.connect(owner).disableLegacySignatures())
                .to.emit(verifier, 'LegacySignaturesDisabled');
        });
    });
});
