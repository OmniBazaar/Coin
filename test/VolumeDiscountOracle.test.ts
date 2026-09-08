/**
 * VolumeDiscountOracle Tests
 *
 * Tests:
 * - Tier logic (ascending lookup, boundary conditions)
 * - Authorized updater access control
 * - Volume update + discount lookup
 * - Tier scheduling/applying/cancelling (timelock)
 * - Edge cases: zero volume, max discount
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe("VolumeDiscountOracle", function () {
    let oracle: any;
    let owner: any, updater1: any, updater2: any, trader1: any, trader2: any, nonOwner: any;
    const TIMELOCK_48H = 48 * 60 * 60;

    beforeEach(async function () {
        [owner, updater1, updater2, trader1, trader2, nonOwner] = await ethers.getSigners();

        const VolumeDiscountOracle = await ethers.getContractFactory("VolumeDiscountOracle");
        oracle = await VolumeDiscountOracle.deploy(
            await owner.getAddress(),
            [await updater1.getAddress(), await updater2.getAddress()]
        );
        await oracle.waitForDeployment();
    });

    describe("Deployment", function () {
        it("Should deploy with default tiers", async function () {
            expect(await oracle.tierCount()).to.equal(3);
            const tier0 = await oracle.tiers(0);
            expect(tier0.threshold).to.equal(ethers.parseUnits("100000", 18));
            expect(tier0.discountBps).to.equal(2);
        });

        it("Should set initial updaters", async function () {
            expect(await oracle.authorizedUpdaters(await updater1.getAddress())).to.be.true;
            expect(await oracle.authorizedUpdaters(await updater2.getAddress())).to.be.true;
            expect(await oracle.authorizedUpdaters(await nonOwner.getAddress())).to.be.false;
        });
    });

    describe("Volume Updates", function () {
        it("Should allow authorized updater to batch update", async function () {
            const traders = [await trader1.getAddress(), await trader2.getAddress()];
            const volumes = [ethers.parseUnits("500000", 18), ethers.parseUnits("5000000", 18)];

            await expect(
                oracle.connect(updater1).updateVolumes(traders, volumes)
            ).to.emit(oracle, "VolumesUpdated").withArgs(await updater1.getAddress(), 2);

            expect(await oracle.traderVolume30d(traders[0])).to.equal(volumes[0]);
            expect(await oracle.traderVolume30d(traders[1])).to.equal(volumes[1]);
        });

        it("Should revert for unauthorized updater", async function () {
            await expect(
                oracle.connect(nonOwner).updateVolumes(
                    [await trader1.getAddress()],
                    [ethers.parseUnits("100", 18)]
                )
            ).to.be.revertedWithCustomError(oracle, "NotAuthorized");
        });

        it("Should revert on mismatched array lengths", async function () {
            await expect(
                oracle.connect(updater1).updateVolumes(
                    [await trader1.getAddress(), await trader2.getAddress()],
                    [ethers.parseUnits("100", 18)]
                )
            ).to.be.revertedWithCustomError(oracle, "ArrayLengthMismatch");
        });
    });

    describe("Discount Lookup", function () {
        beforeEach(async function () {
            // Set volumes: trader1 = 500K, trader2 = 15M
            await oracle.connect(updater1).updateVolumes(
                [await trader1.getAddress(), await trader2.getAddress()],
                [ethers.parseUnits("500000", 18), ethers.parseUnits("15000000", 18)]
            );
        });

        it("Should return 2bps for 500K volume (tier 1)", async function () {
            const discount = await oracle.getDiscountBps(
                await trader1.getAddress(), ethers.ZeroHash
            );
            expect(discount).to.equal(2);
        });

        it("Should return 8bps for 15M volume (tier 3)", async function () {
            const discount = await oracle.getDiscountBps(
                await trader2.getAddress(), ethers.ZeroHash
            );
            expect(discount).to.equal(8);
        });

        it("Should return 0 for zero volume", async function () {
            const discount = await oracle.getDiscountBps(
                await nonOwner.getAddress(), ethers.ZeroHash
            );
            expect(discount).to.equal(0);
        });

        it("Should return 0 for below-threshold volume", async function () {
            await oracle.connect(updater1).updateVolumes(
                [await nonOwner.getAddress()],
                [ethers.parseUnits("50000", 18)]
            );
            const discount = await oracle.getDiscountBps(
                await nonOwner.getAddress(), ethers.ZeroHash
            );
            expect(discount).to.equal(0);
        });

        it("Should return exactly tier discount at boundary", async function () {
            // Exactly at 100K threshold
            await oracle.connect(updater1).updateVolumes(
                [await nonOwner.getAddress()],
                [ethers.parseUnits("100000", 18)]
            );
            const discount = await oracle.getDiscountBps(
                await nonOwner.getAddress(), ethers.ZeroHash
            );
            expect(discount).to.equal(2);
        });
    });

    describe("Updater Management", function () {
        it("Should add updater", async function () {
            await expect(
                oracle.addUpdater(await nonOwner.getAddress())
            ).to.emit(oracle, "UpdaterChanged")
                .withArgs(await nonOwner.getAddress(), true);

            expect(await oracle.authorizedUpdaters(await nonOwner.getAddress())).to.be.true;
        });

        it("Should remove updater", async function () {
            await expect(
                oracle.removeUpdater(await updater1.getAddress())
            ).to.emit(oracle, "UpdaterChanged")
                .withArgs(await updater1.getAddress(), false);

            expect(await oracle.authorizedUpdaters(await updater1.getAddress())).to.be.false;
        });

        it("Should revert addUpdater for non-owner", async function () {
            await expect(
                oracle.connect(nonOwner).addUpdater(await nonOwner.getAddress())
            ).to.be.revertedWithCustomError(oracle, "OwnableUnauthorizedAccount");
        });
    });

    describe("Tier Scheduling", function () {
        const newTiers = [
            { threshold: ethers.parseUnits("50000", 18), discountBps: 1 },
            { threshold: ethers.parseUnits("200000", 18), discountBps: 3 },
            { threshold: ethers.parseUnits("1000000", 18), discountBps: 6 },
            { threshold: ethers.parseUnits("5000000", 18), discountBps: 10 }
        ];

        it("Should schedule tier change", async function () {
            await expect(
                oracle.scheduleTiers(newTiers)
            ).to.emit(oracle, "TiersChangeScheduled");
        });

        it("Should apply after timelock", async function () {
            await oracle.scheduleTiers(newTiers);
            await time.increase(TIMELOCK_48H + 1);

            await expect(oracle.applyTiers()).to.emit(oracle, "TiersChangeApplied");

            expect(await oracle.tierCount()).to.equal(4);
            const tier0 = await oracle.tiers(0);
            expect(tier0.threshold).to.equal(ethers.parseUnits("50000", 18));
            expect(tier0.discountBps).to.equal(1);
        });

        it("Should revert before timelock", async function () {
            await oracle.scheduleTiers(newTiers);
            await expect(
                oracle.applyTiers()
            ).to.be.revertedWithCustomError(oracle, "TimelockNotElapsed");
        });

        it("Should cancel scheduled change", async function () {
            await oracle.scheduleTiers(newTiers);
            await expect(
                oracle.cancelScheduledTiers()
            ).to.emit(oracle, "TiersChangeCancelled");
            // Original tiers still in place
            expect(await oracle.tierCount()).to.equal(3);
        });

        it("Should revert unsorted tiers", async function () {
            const badTiers = [
                { threshold: ethers.parseUnits("200000", 18), discountBps: 3 },
                { threshold: ethers.parseUnits("50000", 18), discountBps: 1 }
            ];
            await expect(
                oracle.scheduleTiers(badTiers)
            ).to.be.revertedWithCustomError(oracle, "TiersNotSorted");
        });

        it("Should revert discount > MAX_DISCOUNT_BPS", async function () {
            const badTiers = [
                { threshold: ethers.parseUnits("100", 18), discountBps: 101 }
            ];
            await expect(
                oracle.scheduleTiers(badTiers)
            ).to.be.revertedWithCustomError(oracle, "DiscountTooHigh");
        });

        it("Should revert > MAX_TIERS", async function () {
            const tooManyTiers = Array.from({ length: 11 }, (_, i) => ({
                threshold: ethers.parseUnits(String((i + 1) * 1000), 18),
                discountBps: i + 1
            }));
            await expect(
                oracle.scheduleTiers(tooManyTiers)
            ).to.be.revertedWithCustomError(oracle, "TooManyTiers");
        });

        it("Should revert double schedule", async function () {
            await oracle.scheduleTiers(newTiers);
            await expect(
                oracle.scheduleTiers(newTiers)
            ).to.be.revertedWithCustomError(oracle, "PendingChangeExists");
        });
    });
});
