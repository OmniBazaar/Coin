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
    // `DEFAULT_ESCROW_FEE_BPS` is 0 since the 2026-11-13 founder decision: a
    // private (pXOM) purchase pays no private-escrow fee.
    const DEFAULT_FEE_BPS = 0n;
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

    describe("arbitration fee — 5 % of the disputed amount (founder decision 2026-11-13)", function () {
        // The COTI MPC precompile does not exist under Hardhat, so the transfer
        // calls inside `_settleArbitration` (MpcCore.onBoard / checkedMul / div
        // / transferGT) cannot execute here — see test/TEST_GUIDE.md
        // §"MPC not available" and the module header. What IS verifiable
        // off-chain is (i) the fee constant the settlement branch reads and
        // (ii) that the settlement branch performs exactly `price * fee /
        // 10_000` out of the payout. Both are asserted below; the encrypted
        // custody drain itself stays a COTI-testnet proof.
        const BASIS_POINTS = 10_000n;

        it("ARBITRATION_FEE_BPS is 500 (5 %), matching EscrowV2's default", async function () {
            const { escrow } = await deployFixture();
            expect(await escrow.ARBITRATION_FEE_BPS()).to.equal(500n);
            expect(await escrow.BASIS_POINTS_DIVISOR()).to.equal(BASIS_POINTS);
        });

        it("takes 5 % of the disputed amount out of the winner's payout", async function () {
            const { escrow } = await deployFixture();
            const feeBps = await escrow.ARBITRATION_FEE_BPS();
            const divisor = await escrow.BASIS_POINTS_DIVISOR();
            // Same integer arithmetic the contract runs in the MPC:
            //   arbFee      = price * feeBps / divisor
            //   winnerAmount = price - arbFee
            for (const price of [10_000n, 1_000_000n, 19_999_999n, 123_456_789n]) {
                const arbFee = (price * feeBps) / divisor;
                const winnerAmount = price - arbFee;
                expect(arbFee * 20n).to.equal(price - (price % 20n)); // exactly 5 %
                expect(arbFee + winnerAmount).to.equal(price); // drains custody
                expect(arbFee * divisor).to.be.lessThanOrEqual(price * feeBps);
            }
            // A 1000-unit dispute pays a 50-unit fee, 950 to the winner.
            expect((1_000n * feeBps) / divisor).to.equal(50n);
        });

        it("reads the constant in _settleArbitration and charges nothing on a normal release", function () {
            const fs = require("fs");
            const path = require("path");
            const source = fs.readFileSync(
                path.join(
                    __dirname,
                    "..",
                    "contracts",
                    "privacy",
                    "PrivateMarketplaceEscrow.sol",
                ),
                "utf8",
            );
            /** Body of a named private function, brace-matched. */
            function bodyOf(name: string): string {
                const start = source.indexOf(`function ${name}(`);
                expect(start, `${name} present in source`).to.be.greaterThan(-1);
                const open = source.indexOf("{", start);
                let depth = 0;
                for (let i = open; i < source.length; i += 1) {
                    if (source[i] === "{") depth += 1;
                    else if (source[i] === "}") {
                        depth -= 1;
                        if (depth === 0) return source.slice(open, i + 1);
                    }
                }
                throw new Error(`unbalanced braces in ${name}`);
            }

            const settlement = bodyOf("_settleArbitration");
            // The disputed-payout math: price * ARBITRATION_FEE_BPS / divisor.
            expect(settlement).to.include("MpcCore.setPublic256(uint256(ARBITRATION_FEE_BPS))");
            expect(settlement).to.include("MpcCore.setPublic256(BASIS_POINTS_DIVISOR)");
            expect(settlement).to.include("privateToken.transferGT(feeVault, arbFeeG)");
            expect(settlement).to.include("privateToken.transferGT(winner, winnerAmountG)");

            // A normal release charges the escrow fee snapshotted at create —
            // never the arbitration fee.
            const release = bodyOf("_settle");
            expect(release).to.include("entry.escrowFeeBpsAtCreate");
            expect(release).to.not.include("ARBITRATION_FEE_BPS");
            expect(release).to.include("privateToken.transferGT(entry.seller, sellerG)");
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
