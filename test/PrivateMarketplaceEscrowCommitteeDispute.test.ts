/**
 * PrivateMarketplaceEscrow -- Committee dispute-resolution authorisation
 *
 * Proves {resolveDisputeWithCommittee}: a random M-of-N validator committee
 * attests the dispute OUTCOME (release-to-buyer vs release-to-seller) and the
 * escrow settles on that attestation -- WITHOUT any `ARBITRATOR_ROLE`
 * (deployer-key) signature. This is the launch-blocker fix: the deployer key is
 * retired shortly after launch, so dispute arbitration must not require a
 * manual deployer action.
 *
 * The committee AUTHORISATION is what this contract change adds; the encrypted
 * payout math (`MpcCore.onBoard` / `transferGT`) runs through the COTI Helium
 * MPC precompile, which is unavailable under Hardhat (per Coin/CLAUDE.md +
 * PrivateMarketplaceEscrow.test.ts). We therefore prove the authorisation
 * boundary two ways:
 *   1. The real `_verifyDisputeOutcome` logic in isolation (via a test-only
 *      external wrapper) -- valid proof authorises, invalid proof / party-in-
 *      committee reject. No MPC, no caller role.
 *   2. The full external `resolveDisputeWithCommittee` on a seeded DISPUTED
 *      escrow -- a valid committee proof from a NON-privileged caller passes
 *      the committee gate (only the Hardhat-absent MPC settlement stops it),
 *      whereas an invalid proof reverts at the committee gate. The differential
 *      proves the committee -- not a role -- is the sole authority.
 *
 * Run with the COTI testnet chain id so the initialize chain-gate passes:
 *   HARDHAT_CHAIN_ID=7082400 npx hardhat test \
 *     test/PrivateMarketplaceEscrowCommitteeDispute.test.ts
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { committeeAttestorLibraries } = require("./utils/committeeAttestorLib");

const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (arr: any[]) => string = ethers.concat;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;

const ETH_SIGNED_PREFIX = "\x19Ethereum Signed Message:\n32";

describe("PrivateMarketplaceEscrow (committee dispute resolution)", function () {
    const N = 5;
    const M = 4; // 4-of-5 supermajority (matches launch config)
    const COTI_CHAIN_IDS = new Set([2632500n, 7082400n]);

    const ESCROW_ID = ethers.id("dispute-escrow-1");

    /** Sort wallets by address ascending (snapshot + sig-order invariant). */
    function sortByAddr(wallets: any[]): any[] {
        return [...wallets].sort((a, b) =>
            a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
        );
    }

    /** Sign `digest` under the EIP-191 envelope (matches _verifyCommittee). */
    function signEthMessage(wallet: any, digest: string): string {
        const ethSigned = keccak256(
            concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
        );
        return new SigningKey(wallet.privateKey).sign(ethSigned).serialized;
    }

    /** Concatenate sigs from `wallets` in ascending-signer-address order. */
    function concatSorted(wallets: any[], digest: string): string {
        return concat(sortByAddr(wallets).map((w) => signEthMessage(w, digest)));
    }

    /** Build a committee proof: commitBlock(32) || sigs. */
    function buildProof(
        commitBlock: number,
        wallets: any[],
        digest: string,
    ): string {
        return concat([ethers.toBeHex(commitBlock, 32), concatSorted(wallets, digest)]);
    }

    /** Confirmed past block whose blockhash (and predecessor's) is available. */
    async function confirmedCommitBlock(): Promise<number> {
        await ethers.provider.send("evm_mine", []);
        return (await ethers.provider.getBlockNumber()) - 1;
    }

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

    /**
     * Deploy the test subclass proxy, bootstrap the committee snapshot with
     * five controlled validator wallets, and bind a dummy backing token. The
     * five validators are the eligible pool; with N == pool size every
     * committee selection returns all five, so any sorted M-subset is a valid
     * quorum regardless of the blockhash seed.
     */
    async function deployFixture() {
        const [admin, relayer, arbitrator, buyer, seller, outsider] =
            await ethers.getSigners();

        // Five validator wallets we control keys for, sorted ascending.
        const validators = sortByAddr(
            Array.from({ length: N }, () =>
                ethers.Wallet.createRandom().connect(ethers.provider),
            ),
        );

        // Deploy the proxy manually (impl + ERC1967Proxy). The test subclass
        // adds helper functions the OZ upgrades plugin refuses to validate, so
        // we bypass `upgrades.deployProxy` — the impl's constructor still runs
        // `_disableInitializers()`, and the proxy runs `initialize` via
        // `initData`, exactly as the production UUPS deploy does.
        const libraries = await committeeAttestorLibraries();
        const Impl = await ethers.getContractFactory(
            "TestPrivateMarketplaceEscrow",
            { libraries },
        );
        const impl = await Impl.deploy();
        await impl.waitForDeployment();
        const initData = Impl.interface.encodeFunctionData("initialize", [
            admin.address,
            [relayer.address],
            [arbitrator.address],
            admin.address, // feeVault (non-zero, non-self)
            ethers.ZeroAddress, // trustedForwarder disabled
        ]);
        const Proxy = await ethers.getContractFactory("ERC1967Proxy");
        const proxy = await Proxy.deploy(await impl.getAddress(), initData);
        await proxy.waitForDeployment();
        const escrow = Impl.attach(await proxy.getAddress());

        // Bootstrap the committee (N, M) + eligible-set snapshot.
        await escrow
            .connect(admin)
            .initializeV2(N, M, validators.map((w) => w.address), 0);

        // Bind a dummy pXOM token (settlement is MPC-gated; never reached here).
        const dummyToken = ethers.Wallet.createRandom().address;
        await escrow.connect(admin).initializeV3(dummyToken);

        return {
            escrow, admin, relayer, arbitrator, buyer, seller, outsider,
            validators,
        };
    }

    describe("digest parity with the off-chain resolver formula", function () {
        it("matches ethers TypedDataEncoder.hash (the Validator PrivateEscrowDisputeResolver formula)", async function () {
            const { escrow, buyer, seller } = await deployFixture();
            const chainId = (await ethers.provider.getNetwork()).chainId;
            const domain = {
                name: "OmniBazaar PrivateMarketplaceEscrow",
                version: "1",
                chainId,
                verifyingContract: await escrow.getAddress(),
            };
            const types = {
                ResolveDisputeOutcome: [
                    { name: "escrowId", type: "bytes32" },
                    { name: "winner", type: "address" },
                ],
            };
            for (const winner of [buyer.address, seller.address]) {
                const offChain = ethers.TypedDataEncoder.hash(domain, types, {
                    escrowId: ESCROW_ID,
                    winner,
                });
                const onChain = await escrow.resolveDisputeDigest(ESCROW_ID, winner);
                // The Validator service (computeResolveDisputeDigest) uses the
                // exact same domain/types/values; this proves that off-chain
                // digest === the digest the contract verifies.
                expect(offChain).to.equal(onChain);
            }
        });
    });

    describe("_verifyDisputeOutcome (committee authorisation, no MPC)", function () {
        it("authorises a valid 4-of-5 committee attestation and returns the attesters", async function () {
            const { escrow, buyer, seller, arbitrator, validators } =
                await deployFixture();

            // The committee decides winner = seller.
            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, seller.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const quorum = validators.slice(0, M); // 4 of 5
            const proof = buildProof(commitBlock, quorum, digest);

            const attesters = await escrow.verifyDisputeOutcome(
                ESCROW_ID,
                seller.address,
                buyer.address,
                seller.address,
                arbitrator.address,
                proof,
            );

            // Authorised: exactly the 4 quorum validators, none of them a party.
            expect(attesters.length).to.equal(M);
            const expected = sortByAddr(quorum).map((w) => w.address);
            expect([...attesters]).to.deep.equal(expected);
        });

        it("rejects a sub-quorum (3-of-5) attestation", async function () {
            const { escrow, buyer, seller, arbitrator, validators } =
                await deployFixture();
            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, seller.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(commitBlock, validators.slice(0, 3), digest);

            await expect(
                escrow.verifyDisputeOutcome(
                    ESCROW_ID, seller.address, buyer.address, seller.address,
                    arbitrator.address, proof,
                ),
            ).to.be.revertedWithCustomError(escrow, "InvalidCommitteeAttestation");
        });

        it("rejects when a named party (buyer) sits on the committee", async function () {
            const { escrow, seller, arbitrator, validators } =
                await deployFixture();

            // Make the buyer BE one of the committee validators (v0). A valid
            // quorum that includes v0 must be rejected — a party cannot attest
            // an outcome they profit from (subject-not-in-committee).
            const partyBuyer = validators[0];
            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, seller.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const quorum = validators.slice(0, M); // includes validators[0]
            const proof = buildProof(commitBlock, quorum, digest);

            await expect(
                escrow.verifyDisputeOutcome(
                    ESCROW_ID, seller.address, partyBuyer.address,
                    seller.address, arbitrator.address, proof,
                ),
            ).to.be.revertedWithCustomError(escrow, "SubjectInCommittee");
        });
    });

    describe("resolveDisputeWithCommittee (full path, no deployer key)", function () {
        it("passes the committee gate for a non-privileged caller on a valid proof (settlement stops only at the MPC boundary)", async function () {
            const { escrow, outsider, buyer, seller, arbitrator, validators } =
                await deployFixture();

            await escrow.seedDisputedEscrow(
                ESCROW_ID, buyer.address, seller.address, arbitrator.address,
            );

            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, seller.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(commitBlock, validators.slice(0, M), digest);

            // The caller (`outsider`) holds NO role. If the committee gate were
            // the blocker we would see InvalidCommitteeAttestation /
            // SubjectInCommittee / EscrowNotDisputed / InvalidWinner. Instead
            // the call proceeds THROUGH authorisation into `_settleArbitration`,
            // where the Hardhat-absent MPC precompile reverts. We assert it does
            // NOT revert with any authorisation error — proving the committee
            // (not a deployer role) authorised the resolution.
            let authError = false;
            try {
                await escrow.connect(outsider).resolveDisputeWithCommittee(
                    ESCROW_ID, seller.address, proof,
                );
            } catch (e: any) {
                const msg = String(e.message ?? e);
                authError = [
                    "InvalidCommitteeAttestation",
                    "SubjectInCommittee",
                    "EscrowNotDisputed",
                    "InvalidWinner",
                ].some((name) => msg.includes(name));
            }
            expect(authError, "committee gate wrongly rejected a valid proof")
                .to.equal(false);
        });

        it("rejects an invalid (sub-quorum) proof at the committee gate", async function () {
            const { escrow, outsider, buyer, seller, arbitrator, validators } =
                await deployFixture();

            await escrow.seedDisputedEscrow(
                ESCROW_ID, buyer.address, seller.address, arbitrator.address,
            );
            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, seller.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const badProof = buildProof(commitBlock, validators.slice(0, 3), digest);

            await expect(
                escrow.connect(outsider).resolveDisputeWithCommittee(
                    ESCROW_ID, seller.address, badProof,
                ),
            ).to.be.revertedWithCustomError(escrow, "InvalidCommitteeAttestation");
        });

        it("reverts EscrowNotDisputed on a non-disputed escrow", async function () {
            const { escrow, outsider, seller, validators } = await deployFixture();
            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, seller.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(commitBlock, validators.slice(0, M), digest);
            await expect(
                escrow.connect(outsider).resolveDisputeWithCommittee(
                    ESCROW_ID, seller.address, proof,
                ),
            ).to.be.revertedWithCustomError(escrow, "EscrowNotDisputed");
        });

        it("reverts InvalidWinner when the winner is neither buyer nor seller", async function () {
            const { escrow, outsider, buyer, seller, arbitrator, validators } =
                await deployFixture();
            await escrow.seedDisputedEscrow(
                ESCROW_ID, buyer.address, seller.address, arbitrator.address,
            );
            const digest = await escrow.resolveDisputeDigest(
                ESCROW_ID, outsider.address,
            );
            const commitBlock = await confirmedCommitBlock();
            const proof = buildProof(commitBlock, validators.slice(0, M), digest);
            await expect(
                escrow.connect(outsider).resolveDisputeWithCommittee(
                    ESCROW_ID, outsider.address, proof,
                ),
            ).to.be.revertedWithCustomError(escrow, "InvalidWinner");
        });
    });

    describe("legacy fallbacks preserved", function () {
        it("still exposes arbitrate (ARBITRATOR_ROLE) and expireDispute", async function () {
            const { escrow } = await deployFixture();
            expect(escrow.interface.hasFunction("arbitrate")).to.equal(true);
            expect(escrow.interface.hasFunction("expireDispute")).to.equal(true);
            expect(
                escrow.interface.hasFunction("resolveDisputeWithCommittee"),
            ).to.equal(true);
        });

        it("arbitrate still requires ARBITRATOR_ROLE (rejects an outsider)", async function () {
            const { escrow, outsider, buyer } = await deployFixture();
            await expect(
                escrow.connect(outsider).arbitrate(ESCROW_ID, buyer.address),
            ).to.be.revertedWithCustomError(
                escrow, "AccessControlUnauthorizedAccount",
            );
        });
    });
});
