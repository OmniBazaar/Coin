const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinReputationCore", function () {
    let reputationCore;
    let identityModule;
    let trustModule;
    let referralModule;
    let config;
    let owner, user1, user2;

    beforeEach(async function () {
        [owner, user1, user2] = await ethers.getSigners();

        // Deploy config
        const Config = await ethers.getContractFactory("OmniCoinConfig");
        config = await Config.deploy(owner.address);

        // Deploy core first with zero module addresses
        const Core = await ethers.getContractFactory("OmniCoinReputationCore");
        reputationCore = await Core.deploy(
            owner.address,
            await config.getAddress(),
            ethers.ZeroAddress,
            ethers.ZeroAddress,
            ethers.ZeroAddress
        );

        // Deploy modules
        const Identity = await ethers.getContractFactory("OmniCoinIdentityVerification");
        identityModule = await Identity.deploy(
            owner.address,
            await reputationCore.getAddress()
        );

        const Trust = await ethers.getContractFactory("OmniCoinTrustSystem");
        trustModule = await Trust.deploy(
            owner.address,
            await reputationCore.getAddress()
        );

        const Referral = await ethers.getContractFactory("OmniCoinReferralSystem");
        referralModule = await Referral.deploy(
            owner.address,
            await reputationCore.getAddress()
        );

        // Update core with module addresses
        await reputationCore.updateIdentityModule(await identityModule.getAddress());
        await reputationCore.updateTrustModule(await trustModule.getAddress());
        await reputationCore.updateReferralModule(await referralModule.getAddress());
    });

    describe("Deployment", function () {
        it("Should set correct admin", async function () {
            const DEFAULT_ADMIN_ROLE = await reputationCore.DEFAULT_ADMIN_ROLE();
            expect(await reputationCore.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it("Should set correct module addresses", async function () {
            expect(await reputationCore.identityModule()).to.equal(await identityModule.getAddress());
            expect(await reputationCore.trustModule()).to.equal(await trustModule.getAddress());
            expect(await reputationCore.referralModule()).to.equal(await referralModule.getAddress());
        });

        it("Should set correct component weights", async function () {
            // Check that weights sum to 10000
            let totalWeight = 0n;
            for (let i = 0; i < 11; i++) {
                const weight = await reputationCore.componentWeights(i);
                totalWeight += weight;
            }
            expect(totalWeight).to.equal(10000n);
        });

        it("Should grant MODULE_ROLE to all modules", async function () {
            const MODULE_ROLE = await reputationCore.MODULE_ROLE();
            expect(await reputationCore.hasRole(MODULE_ROLE, await identityModule.getAddress())).to.be.true;
            expect(await reputationCore.hasRole(MODULE_ROLE, await trustModule.getAddress())).to.be.true;
            expect(await reputationCore.hasRole(MODULE_ROLE, await referralModule.getAddress())).to.be.true;
        });
    });

    describe("MPC Availability", function () {
        it("Should start with MPC disabled", async function () {
            expect(await reputationCore.isMpcAvailable()).to.be.false;
        });

        it("Should allow admin to enable MPC", async function () {
            await reputationCore.setMpcAvailability(true);
            expect(await reputationCore.isMpcAvailable()).to.be.true;
        });

        it("Should reject non-admin MPC changes", async function () {
            await expect(
                reputationCore.connect(user1).setMpcAvailability(true)
            ).to.be.revertedWithCustomError(reputationCore, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Reputation Queries", function () {
        it("Should return zero tier for unverified users", async function () {
            expect(await reputationCore.getPublicReputationTier(user1.address)).to.equal(0);
        });

        it("Should return zero interactions for new users", async function () {
            expect(await reputationCore.getTotalInteractions(user1.address)).to.equal(0);
        });

        it("Should check validator eligibility", async function () {
            // In testnet mode, should always return true
            await config.connect(owner).toggleTestnetMode(); // Toggle to true
            expect(await reputationCore.isEligibleValidator(user1.address)).to.be.true;

            // In production mode, should check requirements
            await config.connect(owner).toggleTestnetMode(); // Toggle back to false
            expect(await reputationCore.isEligibleValidator(user1.address)).to.be.false;
        });
    });

    describe("Component Updates", function () {
        it("Should allow modules to update reputation components", async function () {
            // Grant updater role to identity module (already has MODULE_ROLE)
            
            // Create dummy encrypted value
            const dummyValue = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };

            // Identity module updates identity component
            await identityModule.verifyIdentity(
                user1.address,
                3, // BASIC_ID tier
                ethers.keccak256(ethers.toUtf8Bytes("proof")),
                dummyValue
            );

            // Should increase interactions
            expect(await reputationCore.getTotalInteractions(user1.address)).to.be.gt(0);
        });
    });

    describe("Module Management", function () {
        it("Should allow updating identity module", async function () {
            const newIdentity = ethers.Wallet.createRandom().address;
            await reputationCore.updateIdentityModule(newIdentity);
            expect(await reputationCore.identityModule()).to.equal(newIdentity);
        });

        it("Should revoke role from old module when updating", async function () {
            const MODULE_ROLE = await reputationCore.MODULE_ROLE();
            const oldModule = await identityModule.getAddress();
            
            // Update to new module
            const newModule = ethers.Wallet.createRandom().address;
            await reputationCore.updateIdentityModule(newModule);
            
            // Old module should not have role
            expect(await reputationCore.hasRole(MODULE_ROLE, oldModule)).to.be.false;
            // New module should have role
            expect(await reputationCore.hasRole(MODULE_ROLE, newModule)).to.be.true;
        });
    });

    describe("Weight Management", function () {
        it("Should allow admin to update individual weights", async function () {
            // First need to update all weights to maintain sum of 10000
            const newWeights = [
                2000, 500, 1000, 500, 1000,
                1000, 500, 1000, 1000, 500, 1000
            ];
            await reputationCore.batchUpdateWeights(newWeights);
            expect(await reputationCore.getComponentWeight(0)).to.equal(2000);
        });

        it("Should reject invalid component IDs", async function () {
            await expect(
                reputationCore.setComponentWeight(11, 1000)
            ).to.be.revertedWith("ReputationCore: Invalid component");
        });

        it("Should allow batch weight updates", async function () {
            const newWeights = [
                1000, 1000, 1000, 1000, 1000,
                1000, 1000, 1000, 1000, 500, 500
            ];
            await reputationCore.batchUpdateWeights(newWeights);
            
            for (let i = 0; i < 9; i++) {
                expect(await reputationCore.componentWeights(i)).to.equal(1000);
            }
            expect(await reputationCore.componentWeights(9)).to.equal(500);
            expect(await reputationCore.componentWeights(10)).to.equal(500);
        });

        it("Should reject weights that don't sum to 10000", async function () {
            const badWeights = [
                1000, 1000, 1000, 1000, 1000,
                1000, 1000, 1000, 1000, 1000, 1000
            ]; // Sums to 11000
            
            await expect(
                reputationCore.batchUpdateWeights(badWeights)
            ).to.be.revertedWith("ReputationCore: Weights must sum to 10000");
        });
    });

    describe("Minimum Requirements", function () {
        it("Should update validator minimum", async function () {
            await reputationCore.updateMinValidatorReputation(7500);
            expect(await reputationCore.minValidatorReputation()).to.equal(7500);
        });

        it("Should update arbitrator minimum", async function () {
            await reputationCore.updateMinArbitratorReputation(15000);
            expect(await reputationCore.minArbitratorReputation()).to.equal(15000);
        });
    });

    describe("Pausable", function () {
        it("Should allow admin to pause", async function () {
            await reputationCore.pause();
            expect(await reputationCore.paused()).to.be.true;
        });

        it("Should prevent updates when paused", async function () {
            await reputationCore.pause();
            
            const dummyValue = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };
            
            await expect(
                reputationCore.updateReputationComponent(
                    user1.address,
                    0,
                    dummyValue
                )
            ).to.be.revertedWithCustomError(reputationCore, "EnforcedPause");
        });
    });
});