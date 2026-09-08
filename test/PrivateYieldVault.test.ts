/**
 * PrivateYieldVault -- Non-MPC Logic Tests (settlement-direct escrow, V3)
 *
 * Covers the contract logic that does NOT require the COTI Helium MPC
 * precompile (per test/TEST_GUIDE.md §"MPC not available" — the encrypted
 * custody paths run on COTI testnet, not Hardhat):
 *   1. initializeV3 — binds the backing pXOM token (settlement-direct escrow)
 *   2. stake / stakeWithCommittee guards that revert BEFORE the MPC custody
 *      pull (unbound token PrivateTokenNotSet, RELAYER access control, expired
 *      deadline, bad nonce)
 *   3. unstake / claim lifecycle status guards
 *   4. aprBpsFor pure math + range guards
 *   5. The new `Stake.escrowed` struct field decodes (defaults false for an
 *      EMPTY slot)
 *
 * The actual encrypted custody (transferFromGT at stake, transferGT at
 * unstake) and real pXOM balance deltas are MPC-dependent and proven by the
 * funded-COTI end-to-end test, not here.
 *
 * Run with the COTI testnet chain id so the constructor/initialize chain-gate
 * passes:  HARDHAT_CHAIN_ID=7082400 npx hardhat test test/PrivateYieldVault.test.ts
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { committeeAttestorLibraries } = require("./utils/committeeAttestorLib");

async function getFactory() {
    const libraries = await committeeAttestorLibraries();
    return ethers.getContractFactory("PrivateYieldVault", { libraries });
}

describe("PrivateYieldVault (non-MPC logic)", function () {
    // ctUint256 ABI shape: { ciphertextHigh: uint256, ciphertextLow: uint256 }.
    const ZERO_CT = { ciphertextHigh: 0n, ciphertextLow: 0n };
    // itUint256 ABI shape: { ciphertext: ctUint256, signature: bytes }.
    const ZERO_IT = { ciphertext: ZERO_CT, signature: "0x" };
    // 18-decimal amount-tier minimums: [0, 1M, 10M, 100M, 1B] XOM. Tier-0
    // floor MUST be 0; thresholds 1..4 strictly ascending.
    const AMOUNT_THRESHOLDS = [
        0n,
        ethers.parseEther("1000000"),
        ethers.parseEther("10000000"),
        ethers.parseEther("100000000"),
        ethers.parseEther("1000000000"),
    ];
    // Duration lock periods (seconds): none / 30d / 180d / 730d. Non-decreasing.
    const DURATION_LOCKS = [0n, 2592000n, 15552000n, 63072000n];
    const COTI_CHAIN_IDS = new Set([2632500n, 7082400n]);

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
     * Deploy a UUPS proxy, run initialize -> initializeV3 (binding a dummy
     * non-zero token address — sufficient for every guard test, none of which
     * reach the MPC custody call). The committee reinitializer (2) is skipped;
     * reinitializer(3) does not require a prior reinitializer(2) call, and the
     * RELAYER `stake` path does not need committee parameters.
     */
    async function deployFixture() {
        const [admin, relayer, staker, outsider] = await ethers.getSigners();
        const Factory = await getFactory();
        const vault = await upgrades.deployProxy(
            Factory,
            [
                admin.address,
                [relayer.address],
                AMOUNT_THRESHOLDS,
                DURATION_LOCKS,
                ethers.ZeroAddress, // trustedForwarder disabled
                admin.address, // feeRecipient (any non-zero, non-self address)
            ],
            { initializer: "initialize", kind: "uups", unsafeAllow: ["external-library-linking"] },
        );
        await vault.waitForDeployment();
        // Bind a code-bearing dummy pXOM token (initializeV3 rejects code-less
        // addresses). Guard tests never call into it.
        const MockToken = await ethers.getContractFactory("MockPrivateXom");
        const mockToken = await MockToken.deploy();
        await mockToken.waitForDeployment();
        const dummyToken = await mockToken.getAddress();
        await vault.connect(admin).initializeV3(dummyToken);
        return { vault, admin, relayer, staker, outsider, dummyToken };
    }

    /** Same as deployFixture but WITHOUT initializeV3 (privateToken unbound). */
    async function deployNoV3Fixture() {
        const [admin, relayer, staker, outsider] = await ethers.getSigners();
        const Factory = await getFactory();
        const vault = await upgrades.deployProxy(
            Factory,
            [
                admin.address,
                [relayer.address],
                AMOUNT_THRESHOLDS,
                DURATION_LOCKS,
                ethers.ZeroAddress,
                admin.address,
            ],
            { initializer: "initialize", kind: "uups", unsafeAllow: ["external-library-linking"] },
        );
        await vault.waitForDeployment();
        return { vault, admin, relayer, staker, outsider };
    }

    /** A valid-shaped `stake` (RELAYER) arg tuple — guard-test only. */
    function stakeArgs(staker: string) {
        const future = Math.floor(Date.now() / 1000) + 3600;
        return [
            ethers.id("stake-1"), // stakeId
            staker,
            ZERO_CT, // encAmount (ctUint256)
            0, // amountTier
            0, // durationTier
            0n, // stakerNonce
            BigInt(future), // deadline
            "0x" + "11".repeat(65), // junk signature
        ];
    }

    /** A valid-shaped `stakeWithCommittee` arg tuple — guard-test only. */
    function committeeArgs(staker: string) {
        const future = Math.floor(Date.now() / 1000) + 3600;
        return [
            ethers.id("stake-c-1"),
            staker,
            ZERO_IT, // encAmount (itUint256)
            0,
            0,
            0n,
            BigInt(future),
            "0x" + "11".repeat(65), // staker signature (junk)
            "0x", // committeeProof (empty)
        ];
    }

    describe("initializeV3 (bind backing pXOM token)", function () {
        it("sets privateToken and emits PrivateTokenSet", async function () {
            const { vault, dummyToken } = await deployFixture();
            expect(await vault.privateToken()).to.equal(dummyToken);
        });

        it("reverts on the zero address", async function () {
            const { vault, admin } = await deployNoV3Fixture();
            await expect(
                vault.connect(admin).initializeV3(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(vault, "InvalidAddress");
        });

        it("reverts on a non-zero code-less (EOA) address (audit Low)", async function () {
            const { vault, admin } = await deployNoV3Fixture();
            await expect(
                vault
                    .connect(admin)
                    .initializeV3(ethers.Wallet.createRandom().address),
            ).to.be.revertedWithCustomError(vault, "InvalidAddress");
        });

        it("is admin-gated", async function () {
            const { vault, relayer } = await deployNoV3Fixture();
            await expect(
                vault
                    .connect(relayer)
                    .initializeV3(ethers.Wallet.createRandom().address),
            ).to.be.revertedWithCustomError(
                vault,
                "AccessControlUnauthorizedAccount",
            );
        });

        it("can only be called once (reinitializer)", async function () {
            const { vault, admin } = await deployFixture();
            await expect(
                vault
                    .connect(admin)
                    .initializeV3(ethers.Wallet.createRandom().address),
            ).to.be.revertedWithCustomError(vault, "InvalidInitialization");
        });
    });

    describe("stake guards (pre-MPC)", function () {
        it("reverts PrivateTokenNotSet when the token is unbound", async function () {
            const { vault, relayer, staker } = await deployNoV3Fixture();
            await expect(
                vault.connect(relayer).stake(...stakeArgs(staker.address)),
            ).to.be.revertedWithCustomError(vault, "PrivateTokenNotSet");
        });

        it("rejects a non-RELAYER caller", async function () {
            const { vault, outsider, staker } = await deployFixture();
            await expect(
                vault.connect(outsider).stake(...stakeArgs(staker.address)),
            ).to.be.revertedWithCustomError(
                vault,
                "AccessControlUnauthorizedAccount",
            );
        });
    });

    describe("stakeWithCommittee guards (pre-MPC)", function () {
        it("reverts PrivateTokenNotSet when the token is unbound (first check)", async function () {
            const { vault, staker } = await deployNoV3Fixture();
            await expect(
                vault.stakeWithCommittee(...committeeArgs(staker.address)),
            ).to.be.revertedWithCustomError(vault, "PrivateTokenNotSet");
        });

        it("rejects an expired deadline (token bound)", async function () {
            const { vault, staker } = await deployFixture();
            const args = committeeArgs(staker.address);
            args[6] = 1n; // deadline in the past
            await expect(
                vault.stakeWithCommittee(...args),
            ).to.be.revertedWithCustomError(vault, "DeadlineExpired");
        });

        it("rejects a bad nonce (token bound, valid deadline)", async function () {
            const { vault, staker } = await deployFixture();
            const args = committeeArgs(staker.address);
            args[5] = 7n; // expected nonce is 0
            await expect(
                vault.stakeWithCommittee(...args),
            ).to.be.revertedWithCustomError(vault, "InvalidNonce");
        });
    });

    describe("unstake / claim lifecycle guards", function () {
        it("unstake reverts StakeNotActive on a non-existent stake", async function () {
            const { vault, staker } = await deployFixture();
            await expect(
                vault.connect(staker).unstake(ethers.id("nope")),
            ).to.be.revertedWithCustomError(vault, "StakeNotActive");
        });

        it("accrue reverts StakeNotActive on a non-existent stake", async function () {
            const { vault, staker } = await deployFixture();
            await expect(
                vault.connect(staker).accrue(ethers.id("nope")),
            ).to.be.revertedWithCustomError(vault, "StakeNotActive");
        });

        it("claim reverts NoBalanceToClaim with no accumulated balance", async function () {
            const { vault, staker } = await deployFixture();
            await expect(
                vault.connect(staker).claim(),
            ).to.be.revertedWithCustomError(vault, "NoBalanceToClaim");
        });
    });

    describe("Stake.escrowed struct field", function () {
        it("an EMPTY stake slot decodes escrowed=false, status=0", async function () {
            const { vault } = await deployFixture();
            const s = await vault.stakes(ethers.id("never-staked"));
            expect(s.status).to.equal(0); // EMPTY
            expect(s.escrowed).to.equal(false);
        });
    });

    describe("aprBpsFor (pure)", function () {
        it("(0,0) = 500 bps, (4,3) = 1200 bps", async function () {
            const { vault } = await deployFixture();
            expect(await vault.aprBpsFor(0, 0)).to.equal(500n);
            expect(await vault.aprBpsFor(4, 3)).to.equal(1200n);
        });

        it("reverts on out-of-range tiers", async function () {
            const { vault } = await deployFixture();
            await expect(
                vault.aprBpsFor(5, 0),
            ).to.be.revertedWithCustomError(vault, "InvalidAmountTier");
            await expect(
                vault.aprBpsFor(0, 4),
            ).to.be.revertedWithCustomError(vault, "InvalidDurationTier");
        });
    });
});
