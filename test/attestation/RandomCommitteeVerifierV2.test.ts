/**
 * @file RandomCommitteeVerifierV2.test.ts
 * @description Hardhat tests for `RandomCommitteeVerifierV2` — the
 * grinding-resistant successor to `RandomCommitteeVerifier` that closes
 * TODO.md `COMMITTEE-GRINDING` (memory
 * `security_committee_grinding_gap_2026-07-04`) via mandatory commit-block
 * pinning (`CommitteeSeedPinningLib`).
 *
 * Reuses v1's mocks (`MockBootstrapForAttestation`,
 * `MockOmniCoreForAttestation`, `MockOmniRegistrationForAttestation`) since
 * V2 reads the exact same dependency-contract ABI shape. Does NOT re-test
 * every line V2 shares verbatim with v1 (eligibility math, Fisher-Yates,
 * multi-blockhash seed, sig recovery) — that's already covered by
 * `RandomCommitteeVerifier.test.ts`. Focuses on what's NEW or CHANGED:
 * mandatory pinning, and — the actual point of this contract — an
 * adversarial proof that the grinding attack described in the tracked gap
 * is closed.
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

describe('RandomCommitteeVerifierV2', function () {
    let verifier: any;
    let mockBootstrap: any;
    let mockOmniCore: any;
    let mockOmniRegistration: any;

    let owner: any;
    let v1: any;
    let v2: any;
    let v3: any;
    let v4: any;
    let v5: any;

    const INITIAL_N = 5;
    const INITIAL_M = 4;
    const INITIAL_MIN_TIER = 3;
    const INITIAL_MIN_STAKE = ethers.parseEther('1000000');

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

        const provider = ethers.provider;
        v1 = ethers.Wallet.createRandom().connect(provider);
        v2 = ethers.Wallet.createRandom().connect(provider);
        v3 = ethers.Wallet.createRandom().connect(provider);
        v4 = ethers.Wallet.createRandom().connect(provider);
        v5 = ethers.Wallet.createRandom().connect(provider);

        await deployMocks();

        const Verifier = await ethers.getContractFactory(
            'RandomCommitteeVerifierV2',
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

        for (const v of [v1, v2, v3, v4, v5]) {
            await setEligible(v);
        }
    });

    function signEthMessage(wallet: any, digest: string): string {
        const ethSigned = keccak256(
            concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
        );
        const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
        return sigObj.serialized;
    }

    /**
     * Build a proof = commitBlock(32) || sigs, sorted by signer address
     * ascending, signed over the BOUND digest
     * keccak256(abi.encode(address(this), block.chainid, messageHash,
     * commitBlock)) — the only form V2 accepts (no legacy unbound
     * fallback). Instance/chain binding is audit fix M-05, 2026-08-04.
     */
    async function buildProof(
        commitBlock: number,
        signedBy: any[],
        messageHash: string,
        verifierContract: any = verifier,
    ): Promise<string> {
        const verifierAddress = await verifierContract.getAddress();
        const chainId = (await ethers.provider.getNetwork()).chainId;
        const bound = keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                ['address', 'uint256', 'bytes32', 'uint256'],
                [verifierAddress, chainId, messageHash, commitBlock],
            ),
        );
        const sorted = [...signedBy].sort((a, b) =>
            a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
        );
        const sigs = sorted.map((w) => signEthMessage(w, bound));
        return concat([ethers.toBeHex(commitBlock, 32), ...sigs]);
    }

    /** Pin `messageHash`, mine forward to the pinned block, return it. */
    async function pinAndAdvance(messageHash: string): Promise<number> {
        await verifier.requestCommitteeSeed(messageHash);
        const [pinnedBlock] = await verifier.pinnedCommitBlock(messageHash);
        while (
            (await ethers.provider.getBlockNumber()) <= Number(pinnedBlock)
        ) {
            await ethers.provider.send('evm_mine', []);
        }
        return Number(pinnedBlock);
    }

    // ─────────────────────────────────────────────────── 1. Construction ─

    describe('construction', () => {
        it('exposes immutable dependencies + initial parameters', async () => {
            expect(await verifier.committeeSize()).to.equal(INITIAL_N);
            expect(await verifier.quorumM()).to.equal(INITIAL_M);
            expect(await verifier.minKycTier()).to.equal(INITIAL_MIN_TIER);
            expect(await verifier.minStake()).to.equal(INITIAL_MIN_STAKE);
        });

        it('reports IBridgeVerifier interface metadata', async () => {
            expect(await verifier.verifierVersion()).to.equal(
                'random-committee-ecdsa-v3-pinned',
            );
            expect(await verifier.quorumThreshold()).to.equal(INITIAL_M);
        });

        it('reverts on zero-address dependencies', async () => {
            const Verifier = await ethers.getContractFactory(
                'RandomCommitteeVerifierV2',
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
    });

    // ────────────────────────────────────── 2. Eligibility + snapshot ────

    describe('eligibility + snapshot', () => {
        it('refreshEligibleSet builds a sorted snapshot of qualifying validators', async () => {
            await verifier.refreshEligibleSet();
            const snapshot: string[] = await verifier.eligibleSnapshot();
            expect(snapshot.length).to.equal(5);
        });

        it('isValidator reflects the current snapshot', async () => {
            expect(await verifier.isValidator(v1.address)).to.be.false;
            await verifier.refreshEligibleSet();
            expect(await verifier.isValidator(v1.address)).to.be.true;
        });
    });

    // ──────────── 3. Mandatory commit-block pinning (the whole point) ────

    describe('mandatory commit-block pinning', () => {
        const messageHash = keccak256(toUtf8Bytes('pinning-test-payload'));

        beforeEach(async () => {
            await verifier.refreshEligibleSet();
        });

        it('pinnedCommitBlock is (0,false) before any pin', async () => {
            const [blk, isPinned] = await verifier.pinnedCommitBlock(
                messageHash,
            );
            expect(blk).to.equal(0);
            expect(isPinned).to.be.false;
        });

        it('rejects verify() when no commitBlock was ever pinned', async () => {
            // Even a currently-valid, well-formed 4-of-5 proof over some
            // arbitrary already-mined block must fail — there is no
            // unpinned path in this verifier.
            await ethers.provider.send('evm_mine', []);
            const arbitraryBlock = (await ethers.provider.getBlockNumber()) - 1;
            const proof = await buildProof(
                arbitraryBlock,
                [v1, v2, v3, v4],
                messageHash,
            );
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('rejects verify() with a commitBlock that does not match the live pin', async () => {
            const pinnedBlock = await pinAndAdvance(messageHash);
            const wrongBlock = pinnedBlock - 1;
            const proof = await buildProof(wrongBlock, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });

        it('accepts verify() with the exact pinned commitBlock', async () => {
            const pinnedBlock = await pinAndAdvance(messageHash);
            const proof = await buildProof(pinnedBlock, [v1, v2, v3, v4], messageHash);
            const [valid, attesters] = await verifier.verify(
                messageHash,
                proof,
            );
            expect(valid).to.be.true;
            expect(attesters.length).to.equal(4);
        });

        it('M-01 (2026-08-04, content-hash revision): a refreshEligibleSet() call that GENUINELY changes pool membership invalidates the pin', async () => {
            const pinnedBlock = await pinAndAdvance(messageHash);

            // Add a 6th eligible validator and refresh AFTER pinning —
            // the pool's actual content hash changes (5 -> 6 members,
            // still >= committeeSize so _selectCommittee itself would
            // otherwise still return a result), which must invalidate
            // the already-pinned digest (audit fix M-01).
            const v6 = ethers.Wallet.createRandom().connect(ethers.provider);
            await setEligible(v6);
            await verifier.refreshEligibleSet();

            const proof = await buildProof(pinnedBlock, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(
                valid,
                'verify() must reject a pin whose eligible-pool content hash is stale',
            ).to.be.false;

            const preview = await verifier.committeeFor(messageHash, pinnedBlock);
            expect(
                preview.length,
                'committeeFor() must honestly reflect that verify() will reject this pin post-refresh',
            ).to.equal(0);
        });

        it('M-01 (2026-08-04, content-hash revision): a no-op refreshEligibleSet() call (unchanged pool) does NOT invalidate the pin', async () => {
            const pinnedBlock = await pinAndAdvance(messageHash);

            // Refresh the live eligible set AFTER pinning with NO
            // underlying eligibility change (still v1-v5). This is the
            // exact griefing vector the first (block-number-bound) M-01
            // implementation was vulnerable to — a same-day adversarial
            // re-audit found ANY refresh, even a no-op one, invalidated
            // every outstanding pin unconditionally. The content-hash
            // revision must NOT reject a pin whose pool content is
            // byte-for-byte unchanged.
            await verifier.refreshEligibleSet();

            const proof = await buildProof(pinnedBlock, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(
                valid,
                'verify() must NOT reject a pin after a no-op refresh that left pool content unchanged',
            ).to.be.true;

            const preview = await verifier.committeeFor(messageHash, pinnedBlock);
            expect(
                preview.length,
                'committeeFor() must still show a live preview after a no-op refresh',
            ).to.equal(5);
        });

        it('M-01 (2026-08-04): a pin with no intervening refresh still verifies normally', async () => {
            const pinnedBlock = await pinAndAdvance(messageHash);
            const proof = await buildProof(pinnedBlock, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.true;
        });

        it('rejects a second pin for the same messageHash while the first is live', async () => {
            await verifier.requestCommitteeSeed(messageHash);
            await expect(
                verifier.requestCommitteeSeed(messageHash),
            ).to.be.revertedWithCustomError(verifier, 'DigestAlreadyPinned');
        });

        it('still enforces the multi-blockhash staleness window at the pinned block', async () => {
            const pinnedBlock = await pinAndAdvance(messageHash);
            // Advance far past the 256-block blockhash horizon.
            for (let i = 0; i < 260; i++) {
                await ethers.provider.send('evm_mine', []);
            }
            const proof = await buildProof(pinnedBlock, [v1, v2, v3, v4], messageHash);
            const [valid] = await verifier.verify(messageHash, proof);
            expect(valid).to.be.false;
        });
    });

    // ── 4. Grinding resistance — adversarial proof (TODO.md COMMITTEE-GRINDING) ──

    describe('grinding resistance — adversarial proof', () => {
        // Isolated verifier + mocks (NOT the outer beforeEach's v1-v5) so
        // the pool is exactly 9 and the favorable-block probability math
        // below holds. Pool > committeeSize (9 > 5) so different
        // commitBlocks genuinely yield different committees.
        let localVerifier: any;
        let pool: any[];
        let colluding: any[]; // 4 of 9 — a minority under the M=4 quorum
        const messageHash = keccak256(toUtf8Bytes('grinding-v2-payload'));

        beforeEach(async () => {
            const provider = ethers.provider;
            await deployMocks();
            const Verifier = await ethers.getContractFactory(
                'RandomCommitteeVerifierV2',
            );
            localVerifier = await Verifier.deploy(
                owner.address,
                await mockBootstrap.getAddress(),
                await mockOmniCore.getAddress(),
                await mockOmniRegistration.getAddress(),
                INITIAL_N,
                INITIAL_M,
                INITIAL_MIN_TIER,
                INITIAL_MIN_STAKE,
            );
            await localVerifier.waitForDeployment();

            pool = [];
            for (let i = 0; i < 9; i++) {
                const w = ethers.Wallet.createRandom().connect(provider);
                await setEligible(w);
                pool.push(w);
            }
            colluding = pool.slice(0, 4);
            await localVerifier.refreshEligibleSet();
            expect((await localVerifier.eligibleSnapshot()).length).to.equal(9);
        });

        /** Same enumeration technique as `CommitteeAttestor.test.ts`. */
        async function findFavorableCommitBlock(): Promise<
            number | undefined
        > {
            const colludingLower = colluding.map((w) =>
                w.address.toLowerCase(),
            );
            for (let i = 0; i < 220; i++) {
                await ethers.provider.send('evm_mine', []);
            }
            const head = await ethers.provider.getBlockNumber();
            for (let b = head - 1; b > head - 220; b--) {
                const committee: string[] = await localVerifier.committeeFor(
                    messageHash,
                    b,
                );
                if (committee.length === 0) continue;
                const committeeLower = committee.map((a) => a.toLowerCase());
                if (colludingLower.every((a) => committeeLower.includes(a))) {
                    return b;
                }
            }
            return undefined;
        }

        it('a favorable historical commitBlock exists but cannot be used — no unpinned path', async () => {
            const favorable = await findFavorableCommitBlock();
            expect(
                favorable,
                'expected to find a favorable commitBlock by enumeration (proves the raw Fisher-Yates selection is still grindable in isolation)',
            ).to.not.be.undefined;

            const proof = await buildProof(favorable!, colluding, messageHash, localVerifier);
            const [valid] = await localVerifier.verify(messageHash, proof);
            expect(
                valid,
                'V2 must reject even a favorable commitBlock when it was never pinned',
            ).to.be.false;
        });

        it('the pinned block is the only usable one, regardless of the committee it happens to yield', async () => {
            await localVerifier.requestCommitteeSeed(messageHash);
            const [pinnedBlockBn] = await localVerifier.pinnedCommitBlock(
                messageHash,
            );
            while (
                (await ethers.provider.getBlockNumber()) <=
                Number(pinnedBlockBn)
            ) {
                await ethers.provider.send('evm_mine', []);
            }
            const pinnedBlock = Number(pinnedBlockBn);

            const committee: string[] = await localVerifier.committeeFor(
                messageHash,
                pinnedBlock,
            );
            expect(committee.length).to.equal(5);
            const committeeLower = new Set(
                committee.map((a) => a.toLowerCase()),
            );
            const signers = pool.filter((w) =>
                committeeLower.has(w.address.toLowerCase()),
            );
            expect(signers.length).to.equal(5);

            const proof = await buildProof(pinnedBlock, signers.slice(0, 4), messageHash, localVerifier);
            const [valid] = await localVerifier.verify(messageHash, proof);
            expect(valid, 'the pinned commitBlock verifies normally').to.be
                .true;

            // No fallback to any other commitBlock, favorable or not.
            const otherProof = await buildProof(
                pinnedBlock - 1,
                colluding,
                messageHash,
                localVerifier,
            );
            const [otherValid] = await localVerifier.verify(
                messageHash,
                otherProof,
            );
            expect(
                otherValid,
                'a one-block-off commitBlock must still be rejected',
            ).to.be.false;
        });
    });

    // ─────────────────────────────────────────────── 5. verifyVeto ──

    describe('verifyVeto', () => {
        const vetoHash = keccak256(toUtf8Bytes('fraud-evidence-v2'));

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
        });

        it('rejects sub-supermajority M', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(9, 5, 3, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'QuorumBelowSupermajority');
        });

        it('rejects minKycTier below MIN_KYC_TIER_FLOOR', async () => {
            await expect(
                verifier
                    .connect(owner)
                    .setParameters(5, 4, 2, INITIAL_MIN_STAKE),
            ).to.be.revertedWithCustomError(verifier, 'MinKycTierBelowFloor');
        });
    });
});
