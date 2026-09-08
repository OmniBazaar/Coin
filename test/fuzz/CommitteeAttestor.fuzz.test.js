/**
 * @file CommitteeAttestor.fuzz.test.js
 * @description Invariant fuzzing for CommitteeAttestor — the COTI-side
 *              inheritable base that holds an L1-mirrored eligible-set +
 *              M-of-N committee verification.
 *
 * Each invariant is tested with randomized inputs across valid and
 * boundary ranges. The harness uses Hardhat's native test runner with
 * ethers.js — no external fuzzer dependency.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { committeeAttestorLibraries } = require('../utils/committeeAttestorLib');

const keccak256 = ethers.keccak256;
const toUtf8Bytes = ethers.toUtf8Bytes;
const concat = ethers.concat;
const getBytes = ethers.getBytes;
const SigningKey = ethers.SigningKey;
const AbiCoder = ethers.AbiCoder;

const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';

const SNAPSHOT_UPDATE_DOMAIN = keccak256(
    toUtf8Bytes('OmniBazaar.Privacy.CotiSnapshotUpdate.v1'),
);

/** Simple seeded PRNG for deterministic fuzz runs. */
function mulberry32(a) {
    return function () {
        a |= 0; a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function sortByAddr(wallets) {
    return [...wallets].sort((a, b) =>
        a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
    );
}

function signEthMessage(wallet, digest) {
    const ethSigned = keccak256(
        concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
    );
    const sigObj = new SigningKey(wallet.privateKey).sign(ethSigned);
    return sigObj.serialized;
}

function concatSorted(wallets, digest) {
    const sorted = sortByAddr(wallets);
    const sigs = sorted.map((w) => signEthMessage(w, digest));
    return concat(sigs);
}

function buildVerifyProof(commitBlock, wallets, digest) {
    const commitBlockHex = ethers.toBeHex(commitBlock, 32);
    return concat([commitBlockHex, concatSorted(wallets, digest)]);
}

function snapshotDigest(chainId, contractAddr, sequence, l1Block, setSortedAddrs) {
    const coder = AbiCoder.defaultAbiCoder();
    const setHash = keccak256(coder.encode(['address[]'], [setSortedAddrs]));
    return keccak256(
        coder.encode(
            ['bytes32', 'uint256', 'address', 'uint256', 'uint256', 'bytes32'],
            [SNAPSHOT_UPDATE_DOMAIN, chainId, contractAddr, sequence, l1Block, setHash],
        ),
    );
}

async function confirmedCommitBlock() {
    await ethers.provider.send('evm_mine', []);
    return (await ethers.provider.getBlockNumber()) - 1;
}

async function getAttestorFactory() {
    const libraries = await committeeAttestorLibraries();
    return ethers.getContractFactory('TestCommitteeAttestor', { libraries });
}

describe('CommitteeAttestor — Invariant Fuzzing', function () {
    let attestor;
    let chainId;
    let contractAddr;

    const FUZZ_RUNS = 50;
    const POOL_SIZE = 20;

    beforeEach(async function () {
        const Factory = await getAttestorFactory();
        attestor = await Factory.deploy();
        await attestor.waitForDeployment();
        chainId = BigInt((await ethers.provider.getNetwork()).chainId);
        contractAddr = await attestor.getAddress();
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-01: Committee parameter bounds
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-01: Committee parameter bounds', () => {
        it('rejects N outside [3, 31] across randomized inputs', async () => {
            const rng = mulberry32(0x01);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const n = Math.floor(rng() * 1000) + 1;
                const m = Math.max(1, Math.floor(n * 0.67));
                if (n >= 3 && n <= 31 && m * 3 >= n * 2 && m <= n) {
                    await attestor.init(n, m);
                    expect(await attestor.committeeSize()).to.equal(n);
                    expect(await attestor.quorumM()).to.equal(m);
                    // Re-deploy for next iteration
                    const Factory2 = await getAttestorFactory();
                    attestor = await Factory2.deploy();
                    await attestor.waitForDeployment();
                } else {
                    const Factory2 = await getAttestorFactory();
                    const a = await Factory2.deploy();
                    await a.waitForDeployment();
                    await expect(a.init(n, m)).to.be.reverted;
                }
            }
        });

        it('rejects M < ceil(2N/3) across randomized inputs', async () => {
            const rng = mulberry32(0x02);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const n = 3 + Math.floor(rng() * 28); // [3, 31]
                const m = Math.floor(rng() * n) + 1; // [1, n]
                const Factory2 = await getAttestorFactory();
                const a = await Factory2.deploy();
                await a.waitForDeployment();
                if (m * 3 >= n * 2) {
                    await a.init(n, m);
                    expect(await a.committeeSize()).to.equal(n);
                } else {
                    await expect(a.init(n, m)).to.be.reverted;
                }
            }
        });

        it('rejects M > N across randomized inputs', async () => {
            const rng = mulberry32(0x03);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const n = 3 + Math.floor(rng() * 28);
                const m = n + 1 + Math.floor(rng() * 10);
                const Factory2 = await getAttestorFactory();
                const a = await Factory2.deploy();
                await a.waitForDeployment();
                await expect(a.init(n, m)).to.be.reverted;
            }
        });

        it('rejects setCommitteeParameters when N > pool size (audit L-3 gate)', async () => {
            const rng = mulberry32(0x04);
            const poolWallets = [];
            for (let j = 0; j < 10; j++) {
                poolWallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
            }
            const sorted = sortByAddr(poolWallets).map((w) => w.address);
            await attestor.init(5, 4);
            await attestor.bootstrapSnapshot(sorted, 100, 1);

            for (let i = 0; i < FUZZ_RUNS; i++) {
                const newN = 11 + Math.floor(rng() * 20); // > pool size (10)
                const newM = Math.max(1, Math.floor(newN * 0.67));
                await expect(
                    attestor.setCommitteeParameters(newN, newM),
                ).to.be.reverted;
            }
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-02: Snapshot integrity (sorted, no zero, no dup, mapping consistent)
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-02: Snapshot integrity', () => {
        it('rejects unsorted snapshot across randomized permutations', async () => {
            const rng = mulberry32(0x10);
            await attestor.init(5, 4);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const wallets = [];
                const count = 5 + Math.floor(rng() * 10);
                for (let j = 0; j < count; j++) {
                    wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
                }
                const sorted = sortByAddr(wallets).map((w) => w.address);
                // Fisher-Yates shuffle to create unsorted
                const shuffled = [...sorted];
                for (let k = shuffled.length - 1; k > 0; k--) {
                    const j = Math.floor(rng() * (k + 1));
                    [shuffled[k], shuffled[j]] = [shuffled[j], shuffled[k]];
                }
                // Only test if actually unsorted
                const isSorted = shuffled.every((v, idx, arr) => idx === 0 || v.toLowerCase() > arr[idx - 1].toLowerCase());
                if (!isSorted) {
                    await expect(
                        attestor.bootstrapSnapshot(shuffled, 100, i + 1),
                    ).to.be.reverted;
                }
            }
        });

        it('rejects zero-address in snapshot across randomized positions', async () => {
            const rng = mulberry32(0x11);
            await attestor.init(5, 4);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const wallets = [];
                const count = 5 + Math.floor(rng() * 10);
                for (let j = 0; j < count; j++) {
                    wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
                }
                const sorted = sortByAddr(wallets).map((w) => w.address);
                const zeroPos = Math.floor(rng() * sorted.length);
                sorted[zeroPos] = ethers.ZeroAddress;
                await expect(
                    attestor.bootstrapSnapshot(sorted, 100, i + 1),
                ).to.be.reverted;
            }
        });

        it('rejects duplicate addresses in snapshot', async () => {
            const rng = mulberry32(0x12);
            await attestor.init(5, 4);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const wallets = [];
                const count = 5 + Math.floor(rng() * 10);
                for (let j = 0; j < count; j++) {
                    wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
                }
                const sorted = sortByAddr(wallets).map((w) => w.address);
                const dupPos = Math.floor(rng() * (sorted.length - 1));
                sorted[dupPos + 1] = sorted[dupPos];
                await expect(
                    attestor.bootstrapSnapshot(sorted, 100, i + 1),
                ).to.be.reverted;
            }
        });

        it('isInSnapshot mapping is consistent with array after bootstrap', async () => {
            const rng = mulberry32(0x13);
            await attestor.init(5, 4);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const wallets = [];
                const count = 5 + Math.floor(rng() * 10);
                for (let j = 0; j < count; j++) {
                    wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
                }
                const sorted = sortByAddr(wallets).map((w) => w.address);
                const Factory2 = await getAttestorFactory();
                const a = await Factory2.deploy();
                await a.waitForDeployment();
                await a.init(5, 4);
                await a.bootstrapSnapshot(sorted, 100, i + 1);

                expect(await a.eligibleSnapshotLength()).to.equal(sorted.length);
                for (const addr of sorted) {
                    expect(await a.isInSnapshot(addr)).to.be.true;
                }
                const stranger = ethers.Wallet.createRandom();
                expect(await a.isInSnapshot(stranger.address)).to.be.false;
            }
        });

        it('rejects empty snapshot', async () => {
            await attestor.init(5, 4);
            await expect(attestor.bootstrapSnapshot([], 100, 1)).to.be.reverted;
        });

        it('rejects snapshot exceeding MAX_SNAPSHOT_SIZE (256)', async () => {
            await attestor.init(5, 4);
            const tooBig = [];
            for (let j = 0; j < 257; j++) {
                tooBig.push(ethers.Wallet.createRandom().address);
            }
            tooBig.sort((a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : 1);
            await expect(
                attestor.bootstrapSnapshot(tooBig, 100, 1),
            ).to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-03: Sequence monotonicity
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-03: Sequence monotonicity', () => {
        it('rejects stale or equal sequence across randomized values', async () => {
            const rng = mulberry32(0x20);
            await attestor.init(5, 4);
            const wallets = [];
            for (let j = 0; j < 5; j++) {
                wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
            }
            const sorted = sortByAddr(wallets).map((w) => w.address);
            await attestor.bootstrapSnapshot(sorted, 100, 50);

            for (let i = 0; i < FUZZ_RUNS; i++) {
                const staleSeq = Math.floor(rng() * 51); // [0, 50] — all <= current (50)
                await expect(
                    attestor.bootstrapSnapshot(sorted, 200, staleSeq),
                ).to.be.reverted;
            }
        });

        it('accepts strictly increasing sequences', async () => {
            const rng = mulberry32(0x21);
            await attestor.init(5, 4);
            const wallets = [];
            for (let j = 0; j < 5; j++) {
                wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
            }
            const sorted = sortByAddr(wallets).map((w) => w.address);

            let seq = 1;
            for (let i = 0; i < 20; i++) {
                const Factory2 = await getAttestorFactory();
                const a = await Factory2.deploy();
                await a.waitForDeployment();
                await a.init(5, 4);
                await a.bootstrapSnapshot(sorted, 100, seq);
                expect(await a.eligibleSnapshotSequence()).to.equal(seq);
                seq += 1 + Math.floor(rng() * 100);
            }
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-04: Snapshot update authorization (M-of-N from current set)
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-04: Snapshot update authorization', () => {
        let poolWallets;
        let poolSorted;

        beforeEach(async () => {
            poolWallets = [];
            for (let j = 0; j < POOL_SIZE; j++) {
                poolWallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
            }
            poolSorted = sortByAddr(poolWallets).map((w) => w.address);
            await attestor.init(5, 4);
            await attestor.bootstrapSnapshot(poolSorted, 100, 1);
        });

        async function pushUpdate(newWallets, l1Block, sequence, signers) {
            const newSorted = sortByAddr(newWallets).map((w) => w.address);
            const digest = snapshotDigest(chainId, contractAddr, sequence, l1Block, newSorted);
            const sigs = concatSorted(signers, digest);
            return attestor.pushEligibleSetUpdate(newSorted, l1Block, sequence, sigs);
        }

        it('rejects update signed by non-current-member across randomized non-members', async () => {
            const rng = mulberry32(0x30);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const newSet = [...poolWallets];
                const stranger = ethers.Wallet.createRandom().connect(ethers.provider);
                newSet.push(stranger);
                const signers = [poolWallets[0], poolWallets[1], poolWallets[2], stranger];
                await expect(
                    pushUpdate(newSet, 2000, i + 2, signers),
                ).to.be.reverted;
            }
        });

        it('rejects sub-quorum signer count across randomized deficits', async () => {
            const rng = mulberry32(0x31);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const newSet = [...poolWallets];
                const sigCount = Math.floor(rng() * 4); // [0, 3] — all < M=4
                const signers = poolWallets.slice(0, sigCount);
                await expect(
                    pushUpdate(newSet, 2000, i + 2, signers),
                ).to.be.reverted;
            }
        });

        it('accepts update with exactly M signers from current set', async () => {
            const rng = mulberry32(0x32);
            for (let i = 0; i < 20; i++) {
                const newSet = [...poolWallets];
                const extraCount = Math.floor(rng() * 5);
                for (let k = 0; k < extraCount; k++) {
                    newSet.push(ethers.Wallet.createRandom().connect(ethers.provider));
                }
                const signers = poolWallets.slice(0, 4); // M=4
                await pushUpdate(newSet, 2000, i + 2, signers);
                expect(await attestor.eligibleSnapshotSequence()).to.equal(i + 2);
            }
        });

        it('rejects unsorted-unique signatures', async () => {
            const newSet = [...poolWallets];
            const newSorted = sortByAddr(newSet).map((w) => w.address);
            const digest = snapshotDigest(chainId, contractAddr, 2, 2000, newSorted);
            // Sign with v1, v2, v3, v4 but put v2's sig before v1's
            const sig1 = signEthMessage(poolWallets[1], digest);
            const sig0 = signEthMessage(poolWallets[0], digest);
            const sig2 = signEthMessage(poolWallets[2], digest);
            const sig3 = signEthMessage(poolWallets[3], digest);
            const sigs = concat([sig1, sig0, sig2, sig3]);
            await expect(
                attestor.pushEligibleSetUpdate(newSorted, 2000, 2, sigs),
            ).to.be.reverted;
        });

        it('rejects malformed sig concat (not multiple of 65)', async () => {
            const rng = mulberry32(0x33);
            const newSorted = sortByAddr(poolWallets).map((w) => w.address);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const badLen = 65 + Math.floor(rng() * 64); // [65, 128] but not 130
                if (badLen % 65 === 0) continue;
                const badSigs = '0x' + 'aa'.repeat(badLen);
                await expect(
                    attestor.pushEligibleSetUpdate(newSorted, 2000, i + 2, badSigs),
                ).to.be.reverted;
            }
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-05: Committee verification correctness
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-05: Committee verification correctness', () => {
        let poolWallets;
        let poolSorted;
        const digest = keccak256(toUtf8Bytes('fuzz-verify-digest'));

        beforeEach(async () => {
            poolWallets = [];
            for (let j = 0; j < POOL_SIZE; j++) {
                poolWallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
            }
            poolSorted = sortByAddr(poolWallets).map((w) => w.address);
            await attestor.init(5, 4);
            await attestor.bootstrapSnapshot(poolSorted, 100, 1);
        });

        it('rejects proof with sigCount < quorumM', async () => {
            const rng = mulberry32(0x40);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const commitBlock = await confirmedCommitBlock();
                const sigCount = Math.floor(rng() * 4); // [0, 3]
                const signers = poolWallets.slice(0, sigCount);
                const proof = buildVerifyProof(commitBlock, signers, digest);
                const [valid] = await attestor.verifyCommittee(digest, proof);
                expect(valid).to.be.false;
            }
        });

        it('rejects proof with sigCount > committeeSize', async () => {
            const commitBlock = await confirmedCommitBlock();
            // 6 signers > N=5
            const proof = buildVerifyProof(commitBlock, poolWallets.slice(0, 6), digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects proof with non-committee signer', async () => {
            const rng = mulberry32(0x41);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const commitBlock = await confirmedCommitBlock();
                const stranger = ethers.Wallet.createRandom().connect(ethers.provider);
                // Replace one pool member with stranger
                const signers = [poolWallets[0], poolWallets[1], poolWallets[2], stranger];
                const proof = buildVerifyProof(commitBlock, signers, digest);
                const [valid] = await attestor.verifyCommittee(digest, proof);
                expect(valid).to.be.false;
            }
        });

        it('rejects proof with duplicate signer (not sorted-unique)', async () => {
            const commitBlock = await confirmedCommitBlock();
            const ethSigned = keccak256(
                concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
            );
            const dupSig = new SigningKey(poolWallets[0].privateKey).sign(ethSigned).serialized;
            const sig1 = new SigningKey(poolWallets[1].privateKey).sign(ethSigned).serialized;
            const sig2 = new SigningKey(poolWallets[2].privateKey).sign(ethSigned).serialized;
            const commitBlockHex = ethers.toBeHex(commitBlock, 32);
            const proof = concat([commitBlockHex, dupSig, dupSig, sig1, sig2]);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects stale commitBlock (>256 blocks)', async () => {
            const oldBlock = await confirmedCommitBlock();
            for (let i = 0; i < 260; i++) {
                await ethers.provider.send('evm_mine', []);
            }
            const proof = buildVerifyProof(oldBlock, poolWallets.slice(0, 5), digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('rejects malformed proof length (not 32 + k*65)', async () => {
            const rng = mulberry32(0x42);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const badLen = 32 + Math.floor(rng() * 200);
                if (badLen >= 32 + 65 && (badLen - 32) % 65 === 0) continue;
                const badProof = '0x' + 'bb'.repeat(badLen);
                const [valid] = await attestor.verifyCommittee(digest, badProof);
                expect(valid).to.be.false;
            }
        });

        it('rejects proof shorter than 32 + 65 bytes', async () => {
            const rng = mulberry32(0x43);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const shortLen = Math.floor(rng() * 96) + 1; // [1, 96]
                const shortProof = '0x' + 'cc'.repeat(shortLen);
                const [valid] = await attestor.verifyCommittee(digest, shortProof);
                expect(valid).to.be.false;
            }
        });

        it('rejects commitBlock=0', async () => {
            const proof = buildVerifyProof(0, poolWallets.slice(0, 5), digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('accepts valid proof with exactly quorumM signers', async () => {
            for (let i = 0; i < 20; i++) {
                const commitBlock = await confirmedCommitBlock();
                const committee = await attestor.committeeFor(digest, commitBlock);
                expect(committee.length).to.equal(5);
                const committeeLower = new Set(committee.map((a) => a.toLowerCase()));
                const signers = poolWallets.filter((w) =>
                    committeeLower.has(w.address.toLowerCase()),
                );
                expect(signers.length).to.equal(5);
                const proof = buildVerifyProof(commitBlock, signers.slice(0, 4), digest);
                const [valid, attesters] = await attestor.verifyCommittee(digest, proof);
                expect(valid).to.be.true;
                expect(attesters.length).to.equal(4);
            }
        });

        it('accepts valid proof with all committeeSize signers', async () => {
            for (let i = 0; i < 20; i++) {
                const commitBlock = await confirmedCommitBlock();
                const committee = await attestor.committeeFor(digest, commitBlock);
                expect(committee.length).to.equal(5);
                const committeeLower = new Set(committee.map((a) => a.toLowerCase()));
                const signers = poolWallets.filter((w) =>
                    committeeLower.has(w.address.toLowerCase()),
                );
                expect(signers.length).to.equal(5);
                const proof = buildVerifyProof(commitBlock, signers, digest);
                const [valid, attesters] = await attestor.verifyCommittee(digest, proof);
                expect(valid).to.be.true;
                expect(attesters.length).to.equal(5);
            }
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-06: Seed pinning enforcement
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-06: Seed pinning enforcement', () => {
        let poolWallets;
        let poolSorted;
        const digest = keccak256(toUtf8Bytes('fuzz-pin-digest'));

        beforeEach(async () => {
            poolWallets = [];
            for (let j = 0; j < POOL_SIZE; j++) {
                poolWallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
            }
            poolSorted = sortByAddr(poolWallets).map((w) => w.address);
            await attestor.init(5, 4);
            await attestor.bootstrapSnapshot(poolSorted, 100, 1);
        });

        it('when pinning is OFF, any valid commitBlock is accepted', async () => {
            expect(await attestor.committeeSeedPinningRequired()).to.be.false;
            for (let i = 0; i < 20; i++) {
                const commitBlock = await confirmedCommitBlock();
                const committee = await attestor.committeeFor(digest, commitBlock);
                expect(committee.length).to.equal(5);
                const committeeLower = new Set(committee.map((a) => a.toLowerCase()));
                const signers = poolWallets.filter((w) =>
                    committeeLower.has(w.address.toLowerCase()),
                );
                const proof = buildVerifyProof(commitBlock, signers.slice(0, 4), digest);
                const [valid] = await attestor.verifyCommittee(digest, proof);
                expect(valid).to.be.true;
            }
        });

        it('when pinning is ON, non-pinned commitBlock is rejected', async () => {
            await attestor.requireCommitteeSeedPinning();
            expect(await attestor.committeeSeedPinningRequired()).to.be.true;

            const rng = mulberry32(0x51);
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const commitBlock = await confirmedCommitBlock();
                const proof = buildVerifyProof(commitBlock, poolWallets.slice(0, 4), digest);
                const [valid] = await attestor.verifyCommittee(digest, proof);
                expect(valid).to.be.false;
            }
        });

        it('when pinning is ON, pinned commitBlock is accepted', async () => {
            await attestor.requireCommitteeSeedPinning();

            const pinTx = await attestor.requestCommitteeSeed(digest);
            const pinReceipt = await pinTx.wait();
            const [pinnedBlock] = await attestor.pinnedCommitBlock(digest);
            expect(pinnedBlock).to.be.greaterThan(BigInt(pinReceipt.blockNumber));

            while ((await ethers.provider.getBlockNumber()) <= Number(pinnedBlock)) {
                await ethers.provider.send('evm_mine', []);
            }

            const committee = await attestor.committeeFor(digest, pinnedBlock);
            expect(committee.length).to.equal(5);
            const committeeLower = new Set(committee.map((a) => a.toLowerCase()));
            const signers = poolWallets.filter((w) =>
                committeeLower.has(w.address.toLowerCase()),
            );

            const proof = buildVerifyProof(Number(pinnedBlock), signers.slice(0, 4), digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.true;
        });

        it('when pinning is ON, wrong commitBlock (even off-by-one) is rejected', async () => {
            await attestor.requireCommitteeSeedPinning();

            const pinTx = await attestor.requestCommitteeSeed(digest);
            const pinReceipt = await pinTx.wait();
            const [pinnedBlock] = await attestor.pinnedCommitBlock(digest);

            while ((await ethers.provider.getBlockNumber()) <= Number(pinnedBlock)) {
                await ethers.provider.send('evm_mine', []);
            }

            const committee = await attestor.committeeFor(digest, pinnedBlock);
            const committeeLower = new Set(committee.map((a) => a.toLowerCase()));
            const signers = poolWallets.filter((w) =>
                committeeLower.has(w.address.toLowerCase()),
            );

            // Use pinnedBlock - 1 instead of pinnedBlock
            const wrongBlock = Number(pinnedBlock) - 1;
            const proof = buildVerifyProof(wrongBlock, signers.slice(0, 4), digest);
            const [valid] = await attestor.verifyCommittee(digest, proof);
            expect(valid).to.be.false;
        });

        it('committeeSeedPinningRequired is one-way (cannot be unset)', async () => {
            expect(await attestor.committeeSeedPinningRequired()).to.be.false;
            await attestor.requireCommitteeSeedPinning();
            expect(await attestor.committeeSeedPinningRequired()).to.be.true;
            // Calling again doesn't revert but stays true
            await attestor.requireCommitteeSeedPinning();
            expect(await attestor.committeeSeedPinningRequired()).to.be.true;
        });

        it('re-pinning after abandonment (>256 blocks) works', async () => {
            const digest2 = keccak256(toUtf8Bytes('fuzz-repin-digest'));
            await attestor.requestCommitteeSeed(digest2);
            for (let i = 0; i < 260; i++) {
                await ethers.provider.send('evm_mine', []);
            }
            await expect(attestor.requestCommitteeSeed(digest2)).to.not.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-07: ERC-7201 storage isolation
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-07: ERC-7201 storage isolation', () => {
        it('two instances have fully independent state across randomized configs', async () => {
            const rng = mulberry32(0x60);
            const Factory = await getAttestorFactory();

            for (let i = 0; i < 20; i++) {
                const a = await Factory.deploy();
                const b = await Factory.deploy();
                await a.waitForDeployment();
                await b.waitForDeployment();

                const nA = 3 + Math.floor(rng() * 10);
                const mA = Math.max(Math.ceil((nA * 2) / 3), 1);
                const nB = 3 + Math.floor(rng() * 10);
                const mB = Math.max(Math.ceil((nB * 2) / 3), 1);

                await a.init(nA, mA);
                await b.init(nB, mB);

                const walletsA = [];
                const walletsB = [];
                const countA = nA + Math.floor(rng() * 5);
                const countB = nB + Math.floor(rng() * 5);
                for (let j = 0; j < countA; j++) walletsA.push(ethers.Wallet.createRandom().address);
                for (let j = 0; j < countB; j++) walletsB.push(ethers.Wallet.createRandom().address);
                walletsA.sort((x, y) => x.toLowerCase() < y.toLowerCase() ? -1 : 1);
                walletsB.sort((x, y) => x.toLowerCase() < y.toLowerCase() ? -1 : 1);

                await a.bootstrapSnapshot(walletsA, 100, 1);
                await b.bootstrapSnapshot(walletsB, 200, 1);

                expect(await a.committeeSize()).to.equal(nA);
                expect(await b.committeeSize()).to.equal(nB);
                expect(await a.eligibleSnapshotBlock()).to.equal(100);
                expect(await b.eligibleSnapshotBlock()).to.equal(200);
                expect(await a.eligibleSnapshotLength()).to.equal(countA);
                expect(await b.eligibleSnapshotLength()).to.equal(countB);

                // Cross-contamination check
                for (const addr of walletsA) {
                    expect(await a.isInSnapshot(addr)).to.be.true;
                    expect(await b.isInSnapshot(addr)).to.be.false;
                }
                for (const addr of walletsB) {
                    expect(await b.isInSnapshot(addr)).to.be.true;
                    expect(await a.isInSnapshot(addr)).to.be.false;
                }
            }
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    // INV-08: Bootstrap escape hatch (admin override)
    // ═══════════════════════════════════════════════════════════════════════

    describe('INV-08: Bootstrap escape hatch', () => {
        it('bootstrap accepts any valid sorted set regardless of current snapshot', async () => {
            const rng = mulberry32(0x70);
            await attestor.init(5, 4);

            // First bootstrap with set A
            const walletsA = [];
            for (let j = 0; j < 10; j++) {
                walletsA.push(ethers.Wallet.createRandom().address);
            }
            walletsA.sort((x, y) => x.toLowerCase() < y.toLowerCase() ? -1 : 1);
            await attestor.bootstrapSnapshot(walletsA, 100, 1);

            // Bootstrap with completely different set B — no signatures needed
            for (let i = 0; i < FUZZ_RUNS; i++) {
                const walletsB = [];
                const countB = 5 + Math.floor(rng() * 15);
                for (let j = 0; j < countB; j++) {
                    walletsB.push(ethers.Wallet.createRandom().address);
                }
                walletsB.sort((x, y) => x.toLowerCase() < y.toLowerCase() ? -1 : 1);
                await attestor.bootstrapSnapshot(walletsB, 200, i + 2);

                expect(await attestor.eligibleSnapshotLength()).to.equal(countB);
                expect(await attestor.eligibleSnapshotSequence()).to.equal(i + 2);
                for (const addr of walletsB) {
                    expect(await attestor.isInSnapshot(addr)).to.be.true;
                }
                for (const addr of walletsA) {
                    expect(await attestor.isInSnapshot(addr)).to.be.false;
                }
            }
        });

        it('bootstrap rejects invalid sets (same validation as push path)', async () => {
            await attestor.init(5, 4);
            // Unsorted
            const unsorted = [
                ethers.Wallet.createRandom().address,
                ethers.Wallet.createRandom().address,
            ].sort((a, b) => b.toLowerCase().localeCompare(a.toLowerCase()));
            await expect(attestor.bootstrapSnapshot(unsorted, 100, 1)).to.be.reverted;

            // Zero address
            const withZero = [
                ethers.ZeroAddress,
                ethers.Wallet.createRandom().address,
                ethers.Wallet.createRandom().address,
            ].sort((a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : 1);
            await expect(attestor.bootstrapSnapshot(withZero, 100, 1)).to.be.reverted;
        });
    });
});
