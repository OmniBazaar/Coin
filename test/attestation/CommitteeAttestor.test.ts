/**
 * @file CommitteeAttestor.test.ts
 * @description Hardhat tests for `CommitteeAttestor` — the COTI-side
 * inheritable base that holds an L1-mirrored eligible-set + verifies
 * M-of-N committee attestations using the same proof format as the L1
 * `RandomCommitteeVerifier`.
 *
 * Coverage:
 *   - Construction + parameter validation (supermajority math, range)
 *   - Bootstrap snapshot — initial seed via admin path
 *   - pushEligibleSetUpdate: signed-update happy path, sequence monotonicity,
 *     non-current signer rejection, sub-quorum rejection, malformed sigs
 *   - verifyCommittee: happy path + reject (non-committee signer, dup signer,
 *     stale commitBlock, malformed length, sub-quorum)
 *   - Storage isolation across multiple inheriting instances (ERC-7201
 *     namespaced storage)
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { committeeAttestorLibraries } = require('../utils/committeeAttestorLib');

const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (arr: any[]) => string = ethers.concat;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;
const AbiCoder = ethers.AbiCoder;

const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';

const SNAPSHOT_UPDATE_DOMAIN = keccak256(
    toUtf8Bytes('OmniBazaar.Privacy.CotiSnapshotUpdate.v1'),
);

describe('CommitteeAttestor', function () {
    let attestor: any;

    // Five raw wallets we control private keys for.
    let v1: any;
    let v2: any;
    let v3: any;
    let v4: any;
    let v5: any;
    let stranger: any;

    const INITIAL_N = 5;
    const INITIAL_M = 4; // 4-of-5 supermajority

    /**
     * Sort wallets by address ascending (matches the sorted-snapshot
     * invariant + the sig-order requirement).
     */
    function sortByAddr(wallets: any[]): any[] {
        return [...wallets].sort((a, b) =>
            a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
        );
    }

    /**
     * Sign `digest` with `wallet`'s key under the EIP-191 envelope. Returns
     * a 65-byte hex string.
     */
    function signEthMessage(wallet: any, digest: string): string {
        const ethSigned = keccak256(
            concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
        );
        const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
        return sigObj.serialized;
    }

    /**
     * Concatenate sigs in ascending-signer-address order.
     */
    function concatSorted(wallets: any[], digest: string): string {
        const sorted = sortByAddr(wallets);
        const sigs = sorted.map((w) => signEthMessage(w, digest));
        return concat(sigs);
    }

    /**
     * Build a committee verify proof: commitBlock(32) || sigs.
     */
    function buildVerifyProof(
        commitBlock: number,
        wallets: any[],
        digest: string,
    ): string {
        const commitBlockHex = ethers.toBeHex(commitBlock, 32);
        return concat([commitBlockHex, concatSorted(wallets, digest)]);
    }

    /**
     * Build the snapshot-update digest the validators sign.
     */
    function snapshotDigest(
        chainId: bigint,
        contractAddr: string,
        sequence: number,
        l1Block: number,
        setSortedAddrs: string[],
    ): string {
        const coder = AbiCoder.defaultAbiCoder();
        const setHash = keccak256(coder.encode(['address[]'], [setSortedAddrs]));
        return keccak256(
            coder.encode(
                ['bytes32', 'uint256', 'address', 'uint256', 'uint256', 'bytes32'],
                [
                    SNAPSHOT_UPDATE_DOMAIN,
                    chainId,
                    contractAddr,
                    sequence,
                    l1Block,
                    setHash,
                ],
            ),
        );
    }

    /**
     * Get a confirmed past blockhash by mining one extra block.
     */
    async function confirmedCommitBlock(): Promise<number> {
        await ethers.provider.send('evm_mine', []);
        return (await ethers.provider.getBlockNumber()) - 1;
    }

    async function deployAttestor(): Promise<any> {
        const libraries = await committeeAttestorLibraries();
        const Factory = await ethers.getContractFactory(
            'TestCommitteeAttestor',
            { libraries },
        );
        const attestor = await Factory.deploy();
        await attestor.waitForDeployment();
        return attestor;
    }

    beforeEach(async function () {
        const provider = ethers.provider;
        v1 = ethers.Wallet.createRandom().connect(provider);
        v2 = ethers.Wallet.createRandom().connect(provider);
        v3 = ethers.Wallet.createRandom().connect(provider);
        v4 = ethers.Wallet.createRandom().connect(provider);
        v5 = ethers.Wallet.createRandom().connect(provider);
        stranger = ethers.Wallet.createRandom().connect(provider);

        attestor = await deployAttestor();

        await attestor.init(INITIAL_N, INITIAL_M);
    });

    // ───────────────────────────────────────────────────────── 1. Construct ─

    describe('init + parameter validation', () => {
        it('exposes initial committee parameters', async () => {
            expect(await attestor.committeeSize()).to.equal(INITIAL_N);
            expect(await attestor.quorumM()).to.equal(INITIAL_M);
            expect(await attestor.eligibleSnapshotSequence()).to.equal(0);
            expect(await attestor.eligibleSnapshotLength()).to.equal(0);
        });

        it('rejects double-init', async () => {
            await expect(
                attestor.init(INITIAL_N, INITIAL_M),
            ).to.be.revertedWithCustomError(attestor, 'AlreadyInitialized');
        });

        it('rejects M < ⌈2N/3⌉ on parameter update', async () => {
            await expect(
                attestor.setCommitteeParameters(5, 3),
            ).to.be.revertedWithCustomError(attestor, 'QuorumBelowSupermajority');
        });

        it('rejects M > N on parameter update', async () => {
            await expect(
                attestor.setCommitteeParameters(5, 6),
            ).to.be.revertedWithCustomError(attestor, 'QuorumExceedsCommittee');
        });

        it('rejects N below MIN_COMMITTEE_SIZE', async () => {
            await expect(
                attestor.setCommitteeParameters(2, 2),
            ).to.be.revertedWithCustomError(attestor, 'CommitteeSizeOutOfRange');
        });

        it('accepts valid supermajority bump', async () => {
            await attestor.setCommitteeParameters(7, 5); // 5*3=15 ≥ 7*2=14
            expect(await attestor.committeeSize()).to.equal(7);
            expect(await attestor.quorumM()).to.equal(5);
        });
    });

    // ───────────────────────────────────────────────────── 2. Bootstrap ────

    describe('bootstrapSnapshot', () => {
        it('writes a sorted snapshot, marks members, increments sequence', async () => {
            const sorted = sortByAddr([v1, v2, v3, v4, v5]).map((w) => w.address);
            await attestor.bootstrapSnapshot(sorted, 100, 1);

            expect(await attestor.eligibleSnapshotSequence()).to.equal(1);
            expect(await attestor.eligibleSnapshotBlock()).to.equal(100);
            expect(await attestor.eligibleSnapshotLength()).to.equal(5);
            for (const addr of sorted) {
                expect(await attestor.isInSnapshot(addr)).to.be.true;
            }
            expect(await attestor.isInSnapshot(stranger.address)).to.be.false;
        });

        it('rejects empty set', async () => {
            await expect(
                attestor.bootstrapSnapshot([], 100, 1),
            ).to.be.revertedWithCustomError(attestor, 'SnapshotEmpty');
        });

        it('rejects stale sequence on second bootstrap', async () => {
            const sorted = sortByAddr([v1, v2, v3, v4, v5]).map((w) => w.address);
            await attestor.bootstrapSnapshot(sorted, 100, 5);
            await expect(
                attestor.bootstrapSnapshot(sorted, 200, 5),
            ).to.be.revertedWithCustomError(attestor, 'StaleSnapshotSequence');
        });
    });

    // ─────────────────────────── 3. pushEligibleSetUpdate (signed update) ──

    describe('pushEligibleSetUpdate', () => {
        const L1_BLOCK_1 = 1000;

        beforeEach(async () => {
            const sortedAddrs = sortByAddr([v1, v2, v3, v4, v5]).map(
                (w) => w.address,
            );
            await attestor.bootstrapSnapshot(sortedAddrs, L1_BLOCK_1, 1);
        });

        async function pushUpdate(
            newWallets: any[],
            l1Block: number,
            sequence: number,
            signers: any[],
        ): Promise<any> {
            const newSorted = sortByAddr(newWallets).map((w) => w.address);
            const chainId = BigInt((await ethers.provider.getNetwork()).chainId);
            const contractAddr = await attestor.getAddress();
            const digest = snapshotDigest(
                chainId,
                contractAddr,
                sequence,
                l1Block,
                newSorted,
            );
            const sigs = concatSorted(signers, digest);
            return attestor.pushEligibleSetUpdate(
                newSorted,
                l1Block,
                sequence,
                sigs,
            );
        }

        it('accepts a new snapshot signed by 4 current members (M=4)', async () => {
            const newSet = [v1, v2, v3, v4, v5, stranger];
            await pushUpdate(newSet, 2000, 2, [v1, v2, v3, v4]);

            expect(await attestor.eligibleSnapshotSequence()).to.equal(2);
            expect(await attestor.eligibleSnapshotBlock()).to.equal(2000);
            expect(await attestor.eligibleSnapshotLength()).to.equal(6);
            expect(await attestor.isInSnapshot(stranger.address)).to.be.true;
        });

        it('rejects update signed by a non-current member', async () => {
            const newSet = [v1, v2, v3, v4, v5, stranger];
            await expect(
                pushUpdate(newSet, 2000, 2, [v1, v2, v3, stranger]),
            ).to.be.revertedWithCustomError(
                attestor,
                'SnapshotSignerNotInCurrentSet',
            );
        });

        it('rejects sub-quorum (only M-1 signers)', async () => {
            const newSet = [v1, v2, v3, v4, v5, stranger];
            await expect(
                pushUpdate(newSet, 2000, 2, [v1, v2, v3]),
            ).to.be.revertedWithCustomError(
                attestor,
                'InsufficientSnapshotSigners',
            );
        });

        it('rejects stale sequence', async () => {
            const newSet = [v1, v2, v3, v4, v5];
            await expect(
                pushUpdate(newSet, 2000, 1, [v1, v2, v3, v4]),
            ).to.be.revertedWithCustomError(attestor, 'StaleSnapshotSequence');
        });

        it('rejects unsorted set', async () => {
            const unsorted = sortByAddr([v1, v2, v3, v4, v5])
                .reverse()
                .map((w) => w.address);
            const chainId = BigInt((await ethers.provider.getNetwork()).chainId);
            const contractAddr = await attestor.getAddress();
            const digest = snapshotDigest(
                chainId,
                contractAddr,
                2,
                2000,
                unsorted,
            );
            const sigs = concatSorted([v1, v2, v3, v4], digest);
            await expect(
                attestor.pushEligibleSetUpdate(unsorted, 2000, 2, sigs),
            ).to.be.revertedWithCustomError(attestor, 'SnapshotNotSorted');
        });

        it('rejects malformed sig concat length', async () => {
            const newSorted = sortByAddr([v1, v2, v3, v4, v5]).map(
                (w) => w.address,
            );
            await expect(
                attestor.pushEligibleSetUpdate(newSorted, 2000, 2, '0x1234'),
            ).to.be.revertedWithCustomError(
                attestor,
                'SnapshotSigConcatMalformed',
            );
        });

        it('replaces snapshot — old-only members no longer in snapshot', async () => {
            // New set without v5
            const newSet = [v1, v2, v3, v4, stranger];
            const newSorted = sortByAddr(newSet).map((w) => w.address);
            const chainId = BigInt((await ethers.provider.getNetwork()).chainId);
            const contractAddr = await attestor.getAddress();
            const digest = snapshotDigest(chainId, contractAddr, 2, 2000, newSorted);
            const sigs = concatSorted([v1, v2, v3, v4], digest);
            await attestor.pushEligibleSetUpdate(newSorted, 2000, 2, sigs);

            expect(await attestor.isInSnapshot(v5.address)).to.be.false;
            expect(await attestor.isInSnapshot(stranger.address)).to.be.true;
        });
    });

    // ────────────────────────────────────────────── 4. _verifyCommittee ────

    describe('verifyCommittee', () => {
        const digest = keccak256(toUtf8Bytes('test-message-digest'));

        beforeEach(async () => {
            const sortedAddrs = sortByAddr([v1, v2, v3, v4, v5]).map(
                (w) => w.address,
            );
            await attestor.bootstrapSnapshot(sortedAddrs, 100, 1);
        });

        it('verifies a valid 5-of-5 proof', async () => {
            // Pool = N = 5 → committee == full pool. Sign with all 5.
            const commitBlock = await confirmedCommitBlock();
            const proof = buildVerifyProof(commitBlock, [v1, v2, v3, v4, v5], digest);
            const [valid, attesters] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.true;
            expect(attesters.length).to.equal(5);
        });

        it('verifies a valid 4-of-5 quorum proof', async () => {
            const commitBlock = await confirmedCommitBlock();
            // Pool=5 N=5 → committee is the full pool. Any 4 signers work.
            const proof = buildVerifyProof(commitBlock, [v1, v2, v3, v4], digest);
            const [valid, attesters] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.true;
            expect(attesters.length).to.equal(4);
        });

        it('rejects sub-quorum (3 sigs)', async () => {
            const commitBlock = await confirmedCommitBlock();
            const proof = buildVerifyProof(commitBlock, [v1, v2, v3], digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects non-committee signer', async () => {
            // Pool=5, committee=all 5. Stranger is not in pool, so signing fails.
            const commitBlock = await confirmedCommitBlock();
            const proof = buildVerifyProof(commitBlock, [v1, v2, v3, stranger], digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects duplicate signer (not sorted-unique)', async () => {
            const commitBlock = await confirmedCommitBlock();
            const sortedFour = sortByAddr([v1, v2, v3, v4]);
            // Replace the second sig with another copy of the first signer's sig.
            const ethSigned = keccak256(
                concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
            );
            const dupSig = new SigningKey(sortedFour[0].privateKey).sign(ethSigned).serialized;
            const otherSigs = sortedFour.slice(2).map((w) =>
                new SigningKey(w.privateKey).sign(ethSigned).serialized,
            );
            const commitBlockHex = ethers.toBeHex(commitBlock, 32);
            const proof = concat([commitBlockHex, dupSig, dupSig, ...otherSigs]);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects stale commitBlock (>256 blocks old)', async () => {
            const oldBlock = await confirmedCommitBlock();
            // Mine 260 blocks so oldBlock's hash is no longer accessible.
            for (let i = 0; i < 260; i++) {
                await ethers.provider.send('evm_mine', []);
            }
            const proof = buildVerifyProof(oldBlock, [v1, v2, v3, v4, v5], digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects malformed proof length', async () => {
            // 32-byte commitBlock + 100 bytes (not a multiple of 65)
            const commitBlock = await confirmedCommitBlock();
            const commitBlockHex = ethers.toBeHex(commitBlock, 32);
            const proof = concat([
                commitBlockHex,
                '0x' + '11'.repeat(100),
            ]);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects proof too short (no signatures)', async () => {
            const commitBlock = await confirmedCommitBlock();
            const commitBlockHex = ethers.toBeHex(commitBlock, 32);
            const [valid] = await attestor.verifyCommittee(digest, commitBlockHex);
            expect(valid).to.be.false;
        });

        it('rejects setCommitteeParameters when N > current pool size (audit L-3)', async () => {
            // Pool was bootstrapped with 5 in the describe-level beforeEach.
            // Attempting to bump committeeSize to 7 is rejected at param-set
            // time, NOT at verify time. Closes audit L-3: prevents the
            // brick-via-mistuning scenario where verifyCommittee would
            // silently fall through to (false, []) for every call.
            await expect(
                attestor.setCommitteeParameters(7, 5),
            ).to.be.revertedWithCustomError(attestor, 'CommitteeSizeOutOfRange');
        });
    });

    // ──────────── 5. Commit-block pinning (grinding resistance) — units ────

    describe('requestCommitteeSeed / pinnedCommitBlock', () => {
        const pinDigest = keccak256(toUtf8Bytes('pin-unit-test-digest'));

        it('returns (0, false) before any pin', async () => {
            const [blockNo, isPinned] = await attestor.pinnedCommitBlock(
                pinDigest,
            );
            expect(blockNo).to.equal(0);
            expect(isPinned).to.be.false;
        });

        it('pins exactly COMMIT_SEED_PIN_DELAY blocks ahead of the mined tx', async () => {
            const delay = await attestor.COMMIT_SEED_PIN_DELAY();
            const tx = await attestor.requestCommitteeSeed(pinDigest);
            const receipt = await tx.wait();
            const [blockNo, isPinned] = await attestor.pinnedCommitBlock(
                pinDigest,
            );
            expect(isPinned).to.be.true;
            expect(blockNo).to.equal(BigInt(receipt!.blockNumber) + delay);
        });

        it('is permissionless — anyone may pin, and default (unrequired) does not break anything', async () => {
            expect(await attestor.committeeSeedPinningRequired()).to.be.false;
            await expect(attestor.requestCommitteeSeed(pinDigest)).to.not.be
                .reverted;
        });

        it('rejects a second pin for the same digest while the first is still live', async () => {
            await attestor.requestCommitteeSeed(pinDigest);
            await expect(
                attestor.requestCommitteeSeed(pinDigest),
            ).to.be.revertedWithCustomError(attestor, 'DigestAlreadyPinned');
        });

        it('allows re-pinning once the previous pin is abandoned (>256 blocks stale)', async () => {
            await attestor.requestCommitteeSeed(pinDigest);
            for (let i = 0; i < 260; i++) {
                await ethers.provider.send('evm_mine', []);
            }
            await expect(attestor.requestCommitteeSeed(pinDigest)).to.not.be
                .reverted;
        });

        it('committeeSeedPinningRequired flips one-way via _requireCommitteeSeedPinning', async () => {
            expect(await attestor.committeeSeedPinningRequired()).to.be.false;
            await attestor.requireCommitteeSeedPinning();
            expect(await attestor.committeeSeedPinningRequired()).to.be.true;
        });
    });

    // ──── 6. Grinding resistance — adversarial proof (TODO.md COMMITTEE-GRINDING) ────

    describe('grinding resistance — adversarial proof', () => {
        // Pool > committeeSize (9 > 5) so different commitBlocks genuinely
        // yield different committees — the precondition for grinding to be
        // meaningful. At pool == committeeSize (today's 5-validator launch
        // config) every seed yields the whole pool and this attack is a
        // no-op, which is exactly why the gap is currently inert.
        let pool: any[];
        let colluding: any[]; // 4 of 9 — a minority under the M=4 quorum
        const digest = keccak256(toUtf8Bytes('grinding-test-digest'));

        beforeEach(async () => {
            const provider = ethers.provider;
            pool = [];
            for (let i = 0; i < 9; i++) {
                pool.push(ethers.Wallet.createRandom().connect(provider));
            }
            colluding = pool.slice(0, 4);
            const sortedAddrs = sortByAddr(pool).map((w) => w.address);
            await attestor.bootstrapSnapshot(sortedAddrs, 100, 1);
            // N=5, M=4 already set by the outer beforeEach's init(5, 4).
        });

        /**
         * Enumerate confirmed historical blocks the way an on-chain
         * attacker would via the public `committeeFor` view, looking for
         * one whose derived committee fully contains `colluding` — i.e. a
         * commitBlock the 4 colluders alone can satisfy the M=4 quorum
         * with, zero honest participation. ~5/126 ≈ 4% of 5-subsets of a
         * 9-pool contain a specific 4-subset, so searching 220 (of the
         * available ~256) blocks leaves a false-negative probability of
         * roughly (1 - 5/126)^220 ≈ 4e-5 — the test is not meaningfully
         * flaky.
         */
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
                const committee: string[] = await attestor.committeeFor(
                    digest,
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

        it('PRE-FIX: a 4-of-9 minority grinds a commitBlock seating a self-only quorum', async () => {
            const favorable = await findFavorableCommitBlock();
            expect(
                favorable,
                'expected to find a favorable commitBlock by enumeration',
            ).to.not.be.undefined;

            // Proof built from ONLY the 4 colluding signers — no honest
            // validator ever signed anything, yet this clears the M=4
            // quorum because the attacker chose which commitBlock to use.
            const proof = buildVerifyProof(favorable!, colluding, digest);
            const [valid, attesters] = await attestor.verifyCommittee(
                digest,
                proof,
            );
            expect(
                valid,
                'grinding succeeds while pinning is not required (default state — matches the tracked gap)',
            ).to.be.true;
            expect(attesters.length).to.equal(4);
        });

        it('POST-FIX: the identical grinding proof is rejected once pinning is required', async () => {
            const favorable = await findFavorableCommitBlock();
            expect(favorable).to.not.be.undefined;

            await attestor.requireCommitteeSeedPinning();
            expect(await attestor.committeeSeedPinningRequired()).to.be.true;

            const proof = buildVerifyProof(favorable!, colluding, digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(
                valid,
                'a non-pinned (even favorable) commitBlock must be rejected once pinning is required',
            ).to.be.false;
        });

        it('POST-FIX: the only valid path is pin -> wait -> use exactly the pinned block', async () => {
            await attestor.requireCommitteeSeedPinning();

            const pinTx = await attestor.requestCommitteeSeed(digest);
            const pinReceipt = await pinTx.wait();
            const [pinnedBlock] = await attestor.pinnedCommitBlock(digest);
            expect(pinnedBlock).to.be.greaterThan(
                BigInt(pinReceipt!.blockNumber),
            );

            // Mine forward until the pinned block's hash exists.
            while (
                (await ethers.provider.getBlockNumber()) <= Number(pinnedBlock)
            ) {
                await ethers.provider.send('evm_mine', []);
            }

            // Whoever the pin selects, gather that many real signatures —
            // standing in for "the coordinator asks whichever validators
            // the pin selected" (we hold every pool member's key here).
            const committee: string[] = await attestor.committeeFor(
                digest,
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

            const proof = buildVerifyProof(
                Number(pinnedBlock),
                signers.slice(0, 4),
                digest,
            );
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid, 'the pinned commitBlock must verify normally').to.be
                .true;

            // Crucially: NO other commitBlock works — there is no second
            // candidate to grind against, even one block off from the pin.
            const otherBlock = Number(pinnedBlock) - 1;
            const otherProof = buildVerifyProof(otherBlock, colluding, digest);
            const [otherValid] = await attestor.verifyCommittee(
                digest,
                otherProof,
            );
            expect(
                otherValid,
                'any commitBlock other than the live pin must be rejected',
            ).to.be.false;
        });
    });

    // ──────────────────────────── 7. ERC-7201 storage isolation ────────────

    describe('ERC-7201 storage isolation', () => {
        it('two independent attestor instances have disjoint snapshots', async () => {
            const other = await deployAttestor();
            await other.init(INITIAL_N, INITIAL_M);

            const sortedA = sortByAddr([v1, v2, v3, v4, v5]).map((w) => w.address);
            const sortedB = sortByAddr([v1, v2, v3, v4, stranger]).map(
                (w) => w.address,
            );

            await attestor.bootstrapSnapshot(sortedA, 100, 1);
            await other.bootstrapSnapshot(sortedB, 200, 1);

            expect(await attestor.eligibleSnapshotBlock()).to.equal(100);
            expect(await other.eligibleSnapshotBlock()).to.equal(200);
            expect(await attestor.isInSnapshot(v5.address)).to.be.true;
            expect(await other.isInSnapshot(v5.address)).to.be.false;
            expect(await attestor.isInSnapshot(stranger.address)).to.be.false;
            expect(await other.isInSnapshot(stranger.address)).to.be.true;
        });
    });
});
