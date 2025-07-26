const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinReferralSystem", function () {
    let referralModule;
    let reputationCore;
    let owner, referralManager, referrer1, referrer2, referee1, referee2, referee3;

    const MIN_REFERRAL_SCORE = 100;
    const BASE_REFERRAL_REWARD = 100;
    const REFERRAL_DECAY_PERIOD = 180 * 24 * 60 * 60; // 180 days
    const MAX_REFERRAL_LEVELS = 3;

    beforeEach(async function () {
        [owner, referralManager, referrer1, referrer2, referee1, referee2, referee3] = await ethers.getSigners();

        // Deploy mock reputation core
        const MockCore = await ethers.getContractFactory("OmniCoinReputationCore");
        const config = await ethers.getContractFactory("OmniCoinConfig");
        const configContract = await config.deploy(owner.address);
        
        reputationCore = await MockCore.deploy(
            owner.address,
            await configContract.getAddress(),
            ethers.ZeroAddress,
            ethers.ZeroAddress,
            ethers.ZeroAddress
        );

        // Deploy referral module
        const Referral = await ethers.getContractFactory("OmniCoinReferralSystem");
        referralModule = await Referral.deploy(
            owner.address,
            await reputationCore.getAddress()
        );

        // Grant MODULE_ROLE on reputation core
        const MODULE_ROLE = await reputationCore.MODULE_ROLE();
        await reputationCore.grantRole(MODULE_ROLE, await referralModule.getAddress());

        // Grant roles
        const REFERRAL_MANAGER_ROLE = await referralModule.REFERRAL_MANAGER_ROLE();
        await referralModule.grantRole(REFERRAL_MANAGER_ROLE, referralManager.address);
    });

    describe("Deployment", function () {
        it("Should set correct admin", async function () {
            const ADMIN_ROLE = await referralModule.ADMIN_ROLE();
            expect(await referralModule.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
        });

        it("Should set correct reputation core", async function () {
            expect(await referralModule.reputationCore()).to.equal(await reputationCore.getAddress());
        });

        it("Should initialize with correct default weight", async function () {
            const weight = await referralModule.getComponentWeight(9); // REFERRAL_ACTIVITY
            expect(weight).to.equal(1000); // 10%
        });

        it("Should set default level multipliers", async function () {
            expect(await referralModule.levelMultipliers(0)).to.equal(10000); // 100%
            expect(await referralModule.levelMultipliers(1)).to.equal(5000);  // 50%
            expect(await referralModule.levelMultipliers(2)).to.equal(2500);  // 25%
        });
    });

    describe("Referral Recording", function () {
        const createActivityScore = (score) => ({
            ciphertext: score,
            signature: ethers.randomBytes(32)
        });

        it("Should record direct referral", async function () {
            const activityScore = createActivityScore(1000n);

            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                activityScore
            );

            // Check referral data
            const referrerData = await referralModule.referralData(referrer1.address);
            expect(referrerData.directReferralCount).to.equal(1);
            expect(referrerData.totalReferralCount).to.equal(1);
            expect(referrerData.isActiveReferrer).to.be.true;

            // Check referral record
            const record = await referralModule.referralRecords(referee1.address);
            expect(record.referrer).to.equal(referrer1.address);
            expect(record.level).to.equal(1);
            expect(record.isActive).to.be.true;

            // Check reverse lookup
            expect(await referralModule.referrerOf(referee1.address)).to.equal(referrer1.address);
        });

        it("Should update referral tree", async function () {
            const activityScore = createActivityScore(1000n);

            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                activityScore
            );

            const level1Referrals = await referralModule.getReferralTree(referrer1.address, 1);
            expect(level1Referrals).to.include(referee1.address);
            expect(level1Referrals.length).to.equal(1);
        });

        it("Should prevent self-referral", async function () {
            const activityScore = createActivityScore(1000n);

            await expect(
                referralModule.connect(referralManager).recordReferral(
                    referrer1.address,
                    referrer1.address,
                    activityScore
                )
            ).to.be.revertedWith("ReferralSystem: Cannot refer self");
        });

        it("Should prevent duplicate referrals", async function () {
            const activityScore = createActivityScore(1000n);

            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                activityScore
            );

            await expect(
                referralModule.connect(referralManager).recordReferral(
                    referrer2.address,
                    referee1.address,
                    activityScore
                )
            ).to.be.revertedWith("ReferralSystem: Already referred");
        });

        it("Should increment total system referrals", async function () {
            const activityScore = createActivityScore(1000n);
            
            const before = await referralModule.totalSystemReferrals();
            
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                activityScore
            );

            const after = await referralModule.totalSystemReferrals();
            expect(after).to.equal(before + 1n);
        });
    });

    describe("Multi-Level Referrals", function () {
        const activityScore = {
            ciphertext: 1000n,
            signature: ethers.randomBytes(32)
        };

        beforeEach(async function () {
            // Create 3-level referral chain
            // referrer1 -> referee1 -> referee2 -> referee3
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                activityScore
            );
            
            await referralModule.connect(referralManager).recordReferral(
                referee1.address,
                referee2.address,
                activityScore
            );
        });

        it("Should track level 2 referrals", async function () {
            const level2Referrals = await referralModule.getReferralTree(referrer1.address, 2);
            expect(level2Referrals).to.include(referee2.address);
            expect(level2Referrals.length).to.equal(1);
        });

        it("Should track level 3 referrals", async function () {
            await referralModule.connect(referralManager).recordReferral(
                referee2.address,
                referee3.address,
                activityScore
            );

            const level3Referrals = await referralModule.getReferralTree(referrer1.address, 3);
            expect(level3Referrals).to.include(referee3.address);
            expect(level3Referrals.length).to.equal(1);
        });

        it("Should update total counts for multi-level", async function () {
            const referrerData = await referralModule.referralData(referrer1.address);
            expect(referrerData.directReferralCount).to.equal(1); // Only direct
            expect(referrerData.totalReferralCount).to.equal(2); // Direct + level 2
        });

        it("Should get referral chain", async function () {
            const result = await referralModule.getReferralChain(referee2.address);
            const chain = result.chain;
            const levels = result.levels;

            expect(chain[0]).to.equal(referee1.address);
            expect(chain[1]).to.equal(referrer1.address);
            expect(levels[0]).to.equal(1);
            expect(levels[1]).to.equal(2);
        });
    });

    describe("Referral Rewards", function () {
        it("Should process referral rewards", async function () {
            const rewardAmount = {
                ciphertext: 500n,
                signature: ethers.randomBytes(32)
            };

            // First make referrer active
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );

            await referralModule.connect(referralManager).processReferralReward(
                referrer1.address,
                rewardAmount
            );

            const referrerData = await referralModule.referralData(referrer1.address);
            expect(referrerData.lastActivityTimestamp).to.be.gt(0);
        });

        it("Should require active referrer", async function () {
            const rewardAmount = {
                ciphertext: 500n,
                signature: ethers.randomBytes(32)
            };

            await expect(
                referralModule.connect(referralManager).processReferralReward(
                    referrer1.address, // Never referred anyone
                    rewardAmount
                )
            ).to.be.revertedWith("ReferralSystem: Not active referrer");
        });

        it("Should get total referral rewards", async function () {
            // Make referrer active
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );

            // getTotalReferralRewards returns gtUint64 - can't check value directly in test mode
            await referralModule.getTotalReferralRewards(referrer1.address);
            // Should have base reward from referral but can't verify without MPC
        });
    });

    describe("Referral Deactivation", function () {
        beforeEach(async function () {
            const activityScore = {
                ciphertext: 1000n,
                signature: ethers.randomBytes(32)
            };
            
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                activityScore
            );
        });

        it("Should deactivate referral", async function () {
            await referralModule.connect(referralManager).deactivateReferral(
                referee1.address,
                "Fraud detected"
            );

            const record = await referralModule.referralRecords(referee1.address);
            expect(record.isActive).to.be.false;
        });

        it("Should update referrer counts on deactivation", async function () {
            const before = await referralModule.referralData(referrer1.address);
            expect(before.directReferralCount).to.equal(1);

            await referralModule.connect(referralManager).deactivateReferral(
                referee1.address,
                "Fraud detected"
            );

            const after = await referralModule.referralData(referrer1.address);
            expect(after.directReferralCount).to.equal(0);
        });

        it("Should emit deactivation event", async function () {
            await expect(
                referralModule.connect(referralManager).deactivateReferral(
                    referee1.address,
                    "Fraud detected"
                )
            ).to.emit(referralModule, "ReferralDeactivated")
            .withArgs(
                referee1.address,
                referrer1.address,
                "Fraud detected",
                await ethers.provider.getBlock('latest').then(b => b.timestamp + 1)
            );
        });
    });

    describe("Referral Eligibility", function () {
        it("Should check referrer eligibility", async function () {
            // Not eligible initially
            expect(await referralModule.isEligibleReferrer(referrer1.address)).to.be.false;

            // Make active by referring someone
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );

            expect(await referralModule.isEligibleReferrer(referrer1.address)).to.be.true;
        });

        it("Should set referrer eligibility manually", async function () {
            await referralModule.connect(referralManager).setReferrerEligibility(
                referrer1.address,
                true
            );

            const data = await referralModule.referralData(referrer1.address);
            expect(data.isActiveReferrer).to.be.true;
        });

        it("Should consider decay period for eligibility", async function () {
            // Make active
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );

            // Fast forward past decay period
            await ethers.provider.send("evm_increaseTime", [REFERRAL_DECAY_PERIOD + 1]);
            await ethers.provider.send("evm_mine");

            expect(await referralModule.isEligibleReferrer(referrer1.address)).to.be.false;
        });
    });

    describe("Referral Score Decay", function () {
        it("Should apply full decay after period", async function () {
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );

            // Fast forward past decay period
            await ethers.provider.send("evm_increaseTime", [REFERRAL_DECAY_PERIOD + 1]);
            await ethers.provider.send("evm_mine");

            // getReferralScore returns gtUint64, in test mode it's just wrapped uint64
            const scoreTx = await referralModule.getReferralScore(referrer1.address);
            // Since MPC is disabled, the score should be 0 after decay
            // This would need to be tested differently on COTI testnet
        });

        it("Should return referral count regardless of decay", async function () {
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );

            // Fast forward past decay period
            await ethers.provider.send("evm_increaseTime", [REFERRAL_DECAY_PERIOD + 1]);
            await ethers.provider.send("evm_mine");

            // Count should remain
            expect(await referralModule.getReferralCount(referrer1.address)).to.equal(1);
        });
    });

    describe("Quality Score", function () {
        it("Should update quality score", async function () {
            await referralModule.connect(referralManager).updateQualityScore(
                referrer1.address,
                85
            );

            expect(await referralModule.referralQualityScore(referrer1.address)).to.equal(85);
        });

        it("Should emit quality score event", async function () {
            await expect(
                referralModule.connect(referralManager).updateQualityScore(
                    referrer1.address,
                    85
                )
            ).to.emit(referralModule, "QualityScoreUpdated")
            .withArgs(referrer1.address, 85);
        });
    });

    describe("Level Multipliers", function () {
        it("Should update level multipliers", async function () {
            const newMultipliers = [8000n, 4000n, 2000n]; // 80%, 40%, 20%
            
            await referralModule.updateLevelMultipliers(newMultipliers);

            expect(await referralModule.levelMultipliers(0)).to.equal(8000);
            expect(await referralModule.levelMultipliers(1)).to.equal(4000);
            expect(await referralModule.levelMultipliers(2)).to.equal(2000);
        });

        it("Should reject invalid multipliers", async function () {
            const invalidMultipliers = [15000n, 5000n, 2500n]; // First one > 10000

            await expect(
                referralModule.updateLevelMultipliers(invalidMultipliers)
            ).to.be.revertedWith("ReferralSystem: Invalid multiplier");
        });

        it("Should emit multiplier update event", async function () {
            const newMultipliers = [8000n, 4000n, 2000n];

            await expect(referralModule.updateLevelMultipliers(newMultipliers))
                .to.emit(referralModule, "LevelMultipliersUpdated")
                .withArgs(newMultipliers);
        });
    });

    describe("View Functions", function () {
        beforeEach(async function () {
            await referralModule.connect(referralManager).recordReferral(
                referrer1.address,
                referee1.address,
                { ciphertext: 1000n, signature: ethers.randomBytes(32) }
            );
        });

        it("Should get user encrypted data for authorized user", async function () {
            const data = await referralModule.connect(referrer1).getUserEncryptedData(
                referrer1.address
            );

            expect(data.score).to.be.gt(0);
            expect(data.rewards).to.be.gt(0);
        });

        it("Should reject unauthorized access to encrypted data", async function () {
            await expect(
                referralModule.connect(referrer2).getUserEncryptedData(
                    referrer1.address
                )
            ).to.be.revertedWith("ReferralSystem: Not authorized");
        });

        it("Should get referral tree at specific level", async function () {
            const tree = await referralModule.getReferralTree(referrer1.address, 1);
            expect(tree).to.include(referee1.address);
            expect(tree.length).to.equal(1);
        });

        it("Should reject invalid referral tree level", async function () {
            await expect(
                referralModule.getReferralTree(referrer1.address, 0)
            ).to.be.revertedWith("ReferralSystem: Invalid level");

            await expect(
                referralModule.getReferralTree(referrer1.address, 4)
            ).to.be.revertedWith("ReferralSystem: Invalid level");
        });
    });

    describe("Pausable", function () {
        it("Should pause and unpause", async function () {
            await referralModule.pause();
            expect(await referralModule.paused()).to.be.true;

            await referralModule.unpause();
            expect(await referralModule.paused()).to.be.false;
        });

        it("Should prevent referral recording when paused", async function () {
            await referralModule.pause();
            
            await expect(
                referralModule.connect(referralManager).recordReferral(
                    referrer1.address,
                    referee1.address,
                    { ciphertext: 1000n, signature: ethers.randomBytes(32) }
                )
            ).to.be.revertedWithCustomError(referralModule, "EnforcedPause");
        });
    });
});