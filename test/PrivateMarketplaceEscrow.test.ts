/**
 * PrivateMarketplaceEscrow -- Non-MPC Logic Tests
 *
 * Covers the contract logic that does NOT require the COTI Helium MPC
 * precompile (per test/TEST_GUIDE.md §"MPC not available" — those paths run on
 * COTI testnet, not Hardhat):
 *  1.  initializeV3 — binds the backing pXOM token (settlement-direct migration)
 *  2.  createEscrow input guards that revert BEFORE the MPC custody pull
 *      (zero/self addresses, missing arbitrator role, deadline, fee mismatch,
 *       unbound token (M-2), bad buyer signature)
 *  3.  RELAYER_ROLE access control on createEscrow
 *  4.  feeVault self-address guard (audit M-1)
 *  5.  claim() / BalanceClaimed removed under Option A1 (direct-pay)
 *  6.  Lifecycle status guards on release/refund/dispute/arbitrate/expireDispute
 *
 * The actual encrypted custody (transferFromGT at create, transferGT at
 * settle) and real pXOM balance deltas are MPC-dependent and proven by the
 * funded-COTI end-to-end test, not here.
 *
 * Run with the COTI testnet chain id so the constructor/initialize chain-gate
 * passes:  HARDHAT_CHAIN_ID=7082400 npx hardhat test test/PrivateMarketplaceEscrow.test.ts
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { committeeAttestorLibraries } = require("./utils/committeeAttestorLib");

async function getFactory() {
    const libraries = await committeeAttestorLibraries();
    return ethers.getContractFactory("PrivateMarketplaceEscrow", { libraries });
}

describe("PrivateMarketplaceEscrow (non-MPC logic)", function () {
    const DEFAULT_FEE_BPS = 25n;
    // ctUint256 ABI shape: { ciphertextHigh: uint256, ciphertextLow: uint256 }.
    const ZERO_ENC = { ciphertextHigh: 0n, ciphertextLow: 0n };
    // COTI chain ids — initialize() hard-reverts UnsupportedChain on any
    // other chain. This suite is run with HARDHAT_CHAIN_ID=7082400 (see the
    // module header). When the harness is on a non-COTI chain (e.g. the
    // default 31337 in the full `hardhat test` nightly), skip the whole
    // suite rather than fail every fixture deploy on the chain gate.
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
     * Deploy a UUPS proxy and run initialize -> initializeV3 (binding a dummy
     * non-zero token address — sufficient for every guard test, none of which
     * reach the MPC custody call). Production goes 1 -> 2 -> 3; the committee
     * reinitializer (2) is not needed for the RELAYER createEscrow path.
     */
    async function deployFixture() {
        const [admin, relayer, arbitrator, buyer, seller, outsider] =
            await ethers.getSigners();

        const Factory =
            await getFactory();
        const escrow = await upgrades.deployProxy(
            Factory,
            [
                admin.address,
                [relayer.address],
                [arbitrator.address],
                admin.address, // feeVault (any non-zero, non-self address)
                ethers.ZeroAddress, // trustedForwarder disabled
            ],
            { initializer: "initialize", kind: "uups", unsafeAllow: ["external-library-linking"] },
        );
        await escrow.waitForDeployment();

        // Bind a dummy pXOM token (a fresh EOA address — guard tests never
        // call into it).
        const dummyToken = ethers.Wallet.createRandom().address;
        await escrow.connect(admin).initializeV3(dummyToken);

        return {
            escrow, admin, relayer, arbitrator, buyer, seller, outsider,
            dummyToken,
        };
    }

    /** Same as deployFixture but WITHOUT initializeV3 (privateToken unbound). */
    async function deployNoV3Fixture() {
        const [admin, relayer, arbitrator, buyer, seller] =
            await ethers.getSigners();
        const Factory =
            await getFactory();
        const escrow = await upgrades.deployProxy(
            Factory,
            [
                admin.address,
                [relayer.address],
                [arbitrator.address],
                admin.address,
                ethers.ZeroAddress,
            ],
            { initializer: "initialize", kind: "uups", unsafeAllow: ["external-library-linking"] },
        );
        await escrow.waitForDeployment();
        return { escrow, admin, relayer, arbitrator, buyer, seller };
    }

    /** Build a valid-shaped createEscrow arg tuple that passes every guard up
     *  to the buyer-signature check. */
    function createArgs(buyer: string, seller: string, arbitrator: string) {
        const future = Math.floor(Date.now() / 1000) + 3600;
        return [
            ethers.id("escrow-1"), // escrowId
            buyer,
            seller,
            arbitrator,
            ethers.id("listing-1"), // listingRef
            ZERO_ENC,
            DEFAULT_FEE_BPS,
            BigInt(future),
            "0x" + "11".repeat(65), // 65-byte junk signature -> recovery != buyer
        ];
    }

    describe("initializeV3 (bind backing pXOM token)", function () {
        it("sets privateToken and emits PrivateTokenSet", async function () {
            const { escrow, dummyToken } = await deployFixture();
            expect(await escrow.privateToken()).to.equal(dummyToken);
        });

        it("reverts on the zero address", async function () {
            const { escrow, admin } = await deployNoV3Fixture();
            await expect(
                escrow.connect(admin).initializeV3(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
        });

        it("is admin-gated", async function () {
            const { escrow, relayer } = await deployNoV3Fixture();
            await expect(
                escrow.connect(relayer).initializeV3(
                    ethers.Wallet.createRandom().address,
                ),
            ).to.be.revertedWithCustomError(
                escrow, "AccessControlUnauthorizedAccount",
            );
        });

        it("can only be called once (reinitializer)", async function () {
            const { escrow, admin } = await deployFixture();
            await expect(
                escrow.connect(admin).initializeV3(
                    ethers.Wallet.createRandom().address,
                ),
            ).to.be.revertedWithCustomError(escrow, "InvalidInitialization");
        });
    });

    describe("createEscrow input guards (pre-MPC)", function () {
        it("rejects a zero buyer/seller/arbitrator", async function () {
            const { escrow, relayer, arbitrator } = await deployFixture();
            const args = createArgs(
                ethers.ZeroAddress, ethers.Wallet.createRandom().address,
                arbitrator.address,
            );
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
        });

        it("rejects an arbitrator without ARBITRATOR_ROLE", async function () {
            const { escrow, relayer, buyer, seller, outsider } =
                await deployFixture();
            const args = createArgs(
                buyer.address, seller.address, outsider.address,
            );
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
        });

        it("rejects buyer == seller", async function () {
            const { escrow, relayer, arbitrator, buyer } =
                await deployFixture();
            const args = createArgs(
                buyer.address, buyer.address, arbitrator.address,
            );
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
        });

        it("rejects buyer/seller == the escrow itself (audit M-1)", async function () {
            const { escrow, relayer, arbitrator, seller } =
                await deployFixture();
            const self = await escrow.getAddress();
            const args = createArgs(self, seller.address, arbitrator.address);
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
        });

        it("reverts PrivateTokenNotSet when the token is unbound (audit M-2)", async function () {
            const { escrow, relayer, arbitrator, buyer, seller } =
                await deployNoV3Fixture();
            const args = createArgs(
                buyer.address, seller.address, arbitrator.address,
            );
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "PrivateTokenNotSet");
        });

        it("rejects an expired deadline", async function () {
            const { escrow, relayer, arbitrator, buyer, seller } =
                await deployFixture();
            const args = createArgs(
                buyer.address, seller.address, arbitrator.address,
            );
            args[7] = 1n; // deadline in the past
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "DeadlineExpired");
        });

        it("rejects a mismatched expected fee", async function () {
            const { escrow, relayer, arbitrator, buyer, seller } =
                await deployFixture();
            const args = createArgs(
                buyer.address, seller.address, arbitrator.address,
            );
            args[6] = 9999n; // expectedFeeBps != live fee
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "EscrowFeeMismatch");
        });

        it("rejects an invalid buyer signature", async function () {
            const { escrow, relayer, arbitrator, buyer, seller } =
                await deployFixture();
            const args = createArgs(
                buyer.address, seller.address, arbitrator.address,
            );
            // A structurally valid signature (correct v/s, so ECDSA.recover
            // succeeds) made by someone other than the buyer — recovers to a
            // non-buyer address, tripping the InvalidBuyerSignature check
            // rather than ECDSA's malformed-signature revert.
            args[8] = await seller.signMessage("not the buyer's intent");
            await expect(
                escrow.connect(relayer).createEscrow(...args),
            ).to.be.revertedWithCustomError(escrow, "InvalidBuyerSignature");
        });

        it("rejects a non-RELAYER caller", async function () {
            const { escrow, outsider, arbitrator, buyer, seller } =
                await deployFixture();
            const args = createArgs(
                buyer.address, seller.address, arbitrator.address,
            );
            await expect(
                escrow.connect(outsider).createEscrow(...args),
            ).to.be.revertedWithCustomError(
                escrow, "AccessControlUnauthorizedAccount",
            );
        });
    });

    describe("feeVault self-address guard (audit M-1)", function () {
        it("rejects requestFeeVaultUpdate to the escrow itself", async function () {
            const { escrow, admin } = await deployFixture();
            const self = await escrow.getAddress();
            await expect(
                escrow.connect(admin).requestFeeVaultUpdate(self),
            ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
        });
    });

    describe("Option A1 direct-pay: claim path removed", function () {
        it("no longer exposes claim()", async function () {
            const { escrow } = await deployFixture();
            expect(escrow.interface.hasFunction("claim")).to.equal(false);
        });

        it("no longer declares the BalanceClaimed event", async function () {
            const { escrow } = await deployFixture();
            expect(escrow.interface.hasEvent("BalanceClaimed")).to.equal(false);
        });
    });

    describe("lifecycle status guards", function () {
        it("release reverts on a non-existent (EMPTY) escrow", async function () {
            const { escrow, buyer } = await deployFixture();
            await expect(
                escrow.connect(buyer).release(ethers.id("nope")),
            ).to.be.revertedWithCustomError(escrow, "EscrowNotActive");
        });

        it("refund reverts on a non-existent escrow", async function () {
            const { escrow, seller } = await deployFixture();
            await expect(
                escrow.connect(seller).refund(ethers.id("nope")),
            ).to.be.revertedWithCustomError(escrow, "EscrowNotActive");
        });

        it("arbitrate reverts on a non-disputed escrow", async function () {
            const { escrow, arbitrator, buyer } = await deployFixture();
            await expect(
                escrow.connect(arbitrator).arbitrate(
                    ethers.id("nope"), buyer.address,
                ),
            ).to.be.revertedWithCustomError(escrow, "EscrowNotDisputed");
        });

        it("expireDispute reverts on a non-disputed escrow", async function () {
            const { escrow, buyer } = await deployFixture();
            await expect(
                escrow.connect(buyer).expireDispute(ethers.id("nope")),
            ).to.be.revertedWithCustomError(escrow, "EscrowNotDisputed");
        });

        it("expireCommitteeDispute reverts on a non-disputed escrow (VT-27)", async function () {
            const { escrow } = await deployFixture();
            await expect(
                escrow.expireCommitteeDispute(ethers.id("nope")),
            ).to.be.revertedWithCustomError(escrow, "EscrowNotDisputed");
        });
    });
});
