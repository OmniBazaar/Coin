/**
 * @file CommitteeSeedPinningUpgrade.test.ts
 * @description LOCAL mechanics proof that the COMMITTEE-GRINDING fix's new
 * per-contract `requireCommitteeSeedPinning()` admin setter (Coin commit
 * following `471f81b`) can be added to each of the 5 live COTI privacy
 * contracts via the SAME two-step `requestUpgrade` -> `upgradeToAndCall`
 * gate (audit H-05 back-port; `TIMELOCK_DELAY == 0` under the Pioneer-Phase
 * rule, so there is no wait) already live on every one of them, and that
 * the upgrade preserves all pre-existing {CommitteeAttestor} storage.
 *
 * COTI's public RPC does not support hardhat's fork chainId handshake (see
 * `scripts/dryrun-upgrade-pme-v3-local.ts`), so — following that file's
 * established convention — this reproduces the live state SHAPE locally:
 * deploy the current implementation behind a raw ERC1967 proxy (the exact
 * production pattern, not the OZ plugin), drive it to the same reinitializer
 * version each contract is live at (v3 for PrivateMarketplaceEscrow /
 * PrivateYieldVault, v2 for the other three — see `deployments/coti-mainnet.json`
 * `privacyV2`), then run the identical `requestUpgrade` + `upgradeToAndCall`
 * sequence `scripts/upgrade-committee-seed-pinning.ts` runs for real.
 *
 * This does NOT re-prove the `_verifyCommittee` pinning-gate logic itself —
 * that is the shared, already-inherited `CommitteeAttestor` code, covered by
 * `test/attestation/CommitteeAttestor.test.ts` (53 tests, incl. adversarial
 * grinding proofs) and, end-to-end through a real dispute-resolution path,
 * by `test/PrivateMarketplaceEscrowCommitteeDispute.test.ts`. What this file
 * proves, per contract, is the thing those cannot: that the NEW setter
 * survives the real upgrade mechanics, is admin-gated, is a true one-way
 * latch, and that pre-upgrade committee state is untouched.
 *
 *   HARDHAT_CHAIN_ID=7082400 npx hardhat test test/CommitteeSeedPinningUpgrade.test.ts
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { committeeAttestorLibraries } = require("./utils/committeeAttestorLib");

const COTI_CHAIN_IDS = new Set([2632500n, 7082400n]);
const N = 5;
const M = 4; // 4-of-5 supermajority — matches live launch config.

interface Signers {
    admin: any;
    other: any;
    nonAdmin: any;
}

interface TargetConfig {
    /** Contract name — matches the artifact + the coti-mainnet.json privacyV2 key. */
    name: string;
    /** Whether the live proxy has been driven to reinitializer(3) (initializeV3(pxom_)). */
    hasV3: boolean;
    /** Builds the `initialize(...)` calldata args in declaration order. */
    initArgs: (s: Signers) => unknown[];
}

const TARGETS: TargetConfig[] = [
    {
        name: "PrivateMarketplaceEscrow",
        hasV3: true,
        initArgs: (s) => [
            s.admin.address,
            [s.admin.address], // relayers
            [s.admin.address], // arbitrators
            s.admin.address, // feeVault (non-zero, non-self)
            ethers.ZeroAddress, // trustedForwarder disabled
        ],
    },
    {
        name: "PrivatePredictionMarket",
        hasV3: false,
        initArgs: (s) => [
            s.admin.address,
            [s.admin.address], // relayers
            [s.admin.address], // escrowOracles
            [s.admin.address], // marketOracles
            ethers.ZeroAddress, // trustedForwarder disabled
            s.admin.address, // feeRecipient
        ],
    },
    {
        name: "PrivateDEXSettlement",
        hasV3: false,
        initArgs: (s) => [
            s.admin.address,
            [s.admin.address], // settlers (must be non-empty)
            s.other.address, // liquidityPool (dummy, non-zero)
            s.admin.address, // feeVault
            ethers.ZeroAddress, // trustedForwarder disabled
        ],
    },
    {
        name: "PrivateRWAAMM",
        hasV3: false,
        initArgs: (s) => [
            s.admin.address,
            [s.admin.address], // relayers
            [s.admin.address], // escrowOracles
            ethers.ZeroAddress, // trustedForwarder disabled
            s.admin.address, // feeRecipient
        ],
    },
    {
        name: "PrivateYieldVault",
        hasV3: true,
        initArgs: (s) => [
            s.admin.address,
            [s.admin.address], // relayers
            [0n, ethers.parseEther("1000"), ethers.parseEther("2000"), ethers.parseEther("3000"), ethers.parseEther("4000")], // amountThresholds_[5], tier-0 must be 0, strictly ascending
            [86400, 2592000, 7776000, 31536000], // durationLockPeriods_[4], non-decreasing
            ethers.ZeroAddress, // trustedForwarder disabled
            s.admin.address, // feeRecipient
        ],
    },
];

/** Sort wallets by address ascending (matches the sorted-snapshot invariant). */
function sortByAddr(wallets: any[]): any[] {
    return [...wallets].sort((a, b) =>
        a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
    );
}

describe("COMMITTEE-GRINDING fix — requireCommitteeSeedPinning upgrade path (5 live COTI privacy contracts)", function () {
    before(async function () {
        const net = await ethers.provider.getNetwork();
        if (!COTI_CHAIN_IDS.has(net.chainId)) {
            // eslint-disable-next-line no-console
            console.log(
                `  (skipped: chainId ${net.chainId} is not COTI — rerun with HARDHAT_CHAIN_ID=7082400)`,
            );
            this.skip();
        }
    });

    for (const target of TARGETS) {
        describe(target.name, function () {
            /**
             * Deploy the CURRENT contract behind a raw ERC1967Proxy (the exact
             * production pattern) and drive it to the reinitializer version
             * the live proxy is actually at today, matching
             * `deployments/coti-mainnet.json` `privacyV2.<name>`.
             */
            async function deployFixture() {
                const [admin, other, nonAdmin] = await ethers.getSigners();
                const s: Signers = { admin, other, nonAdmin };

                const validators = sortByAddr(
                    Array.from({ length: N }, () =>
                        ethers.Wallet.createRandom().connect(ethers.provider),
                    ),
                ).map((w) => w.address);

                // Every CommitteeAttestor child now DELEGATECALL-links
                // CommitteeAttestorLib (the VT-27 EIP-170 base extraction),
                // and PrivatePredictionMarket additionally links
                // PrivatePredictionMath. Deploy the math lib first, then
                // merge both into the `libraries` map both factory calls use.
                let extra: Record<string, string> | undefined;
                if (target.name === "PrivatePredictionMarket") {
                    const MathLib = await ethers.getContractFactory(
                        "PrivatePredictionMath",
                    );
                    const mathLib = await MathLib.deploy();
                    await mathLib.waitForDeployment();
                    extra = { PrivatePredictionMath: await mathLib.getAddress() };
                }
                const libraries = await committeeAttestorLibraries(extra);

                const Impl = await ethers.getContractFactory(
                    target.name,
                    { libraries },
                );
                const impl0 = await Impl.deploy();
                await impl0.waitForDeployment();

                const initData = Impl.interface.encodeFunctionData(
                    "initialize",
                    target.initArgs(s),
                );
                const Proxy = await ethers.getContractFactory(
                    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
                );
                const proxy = await Proxy.deploy(await impl0.getAddress(), initData);
                await proxy.waitForDeployment();
                const contract = Impl.attach(await proxy.getAddress());

                await (
                    await contract.connect(admin).initializeV2(N, M, validators, 0)
                ).wait();

                if (target.hasV3) {
                    // PrivateYieldVault's initializeV3 defense-in-depth rejects
                    // a code-less (EOA) address — bind a real deployed contract
                    // address instead (the impl proxy target itself; its actual
                    // interface is irrelevant since this test never calls a
                    // token-moving function).
                    const dummyToken = await impl0.getAddress();
                    await (await contract.connect(admin).initializeV3(dummyToken)).wait();
                }

                return { contract, admin, nonAdmin, validators, libraries };
            }

            it("upgrade preserves committee state and adds an admin-gated, one-way requireCommitteeSeedPinning setter", async function () {
                const { contract, admin, nonAdmin, libraries } = await deployFixture();

                // --- pre-upgrade baseline (must survive the upgrade) ---
                const beforeSize = await contract.committeeSize();
                const beforeM = await contract.quorumM();
                const beforeLen = await contract.eligibleSnapshotLength();
                const beforeSeq = await contract.eligibleSnapshotSequence();
                const beforePinRequired = await contract.committeeSeedPinningRequired();
                expect(beforeSize).to.equal(BigInt(N));
                expect(beforeM).to.equal(BigInt(M));
                expect(beforePinRequired).to.equal(false);

                // --- deploy new impl + run the SAME two-step gate the real
                //     cotiMainnet broadcast script uses (H-05 back-port;
                //     TIMELOCK_DELAY == 0, no wait under Pioneer Phase) ---
                const Factory = await ethers.getContractFactory(
                    target.name,
                    { libraries },
                );
                const newImpl = await Factory.deploy();
                await newImpl.waitForDeployment();
                const newImplAddr = await newImpl.getAddress();

                await (
                    await contract.connect(admin).requestUpgrade(newImplAddr)
                ).wait();
                const upgradeAbi = [
                    "function upgradeToAndCall(address newImplementation,bytes data) external payable",
                ];
                const upgrader = new ethers.Contract(
                    await contract.getAddress(),
                    upgradeAbi,
                    admin,
                );
                await (await upgrader.upgradeToAndCall(newImplAddr, "0x")).wait();

                // --- storage preserved across the upgrade ---
                expect(await contract.committeeSize()).to.equal(beforeSize);
                expect(await contract.quorumM()).to.equal(beforeM);
                expect(await contract.eligibleSnapshotLength()).to.equal(beforeLen);
                expect(await contract.eligibleSnapshotSequence()).to.equal(beforeSeq);
                expect(await contract.committeeSeedPinningRequired()).to.equal(false);

                // --- access control: non-admin cannot flip the latch ---
                await expect(
                    contract.connect(nonAdmin).requireCommitteeSeedPinning(),
                ).to.be.reverted;
                expect(await contract.committeeSeedPinningRequired()).to.equal(false);

                // --- admin flips the one-way latch ---
                await expect(contract.connect(admin).requireCommitteeSeedPinning()).to.emit(
                    contract,
                    "CommitteeSeedPinningRequired",
                );
                expect(await contract.committeeSeedPinningRequired()).to.equal(true);

                // --- one-way: calling again is a harmless no-op, never reverts,
                //     never flips back ---
                await (
                    await contract.connect(admin).requireCommitteeSeedPinning()
                ).wait();
                expect(await contract.committeeSeedPinningRequired()).to.equal(true);

                // --- inherited pinning primitives (already live pre-upgrade,
                //     now consequential) remain reachable post-upgrade ---
                const digest = ethers.id(`${target.name}-smoke-test-digest`);
                await (await contract.requestCommitteeSeed(digest)).wait();
                const [pinnedBlock, isPinned] = await contract.pinnedCommitBlock(digest);
                expect(isPinned).to.equal(true);
                expect(pinnedBlock).to.be.greaterThan(0n);
            });
        });
    }
});
