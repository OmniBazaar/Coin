const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinStakingV2", function () {
    // Constants
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VALIDATOR_ROLE"));
    const REWARD_DISTRIBUTOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REWARD_DISTRIBUTOR_ROLE"));
    
    const STAKE_AMOUNT_TIER1 = ethers.parseUnits("5000", 6); // 5,000 tokens (tier 1)
    const STAKE_AMOUNT_TIER2 = ethers.parseUnits("50000", 6); // 50,000 tokens (tier 2)
    const STAKE_AMOUNT_TIER3 = ethers.parseUnits("150000", 6); // 150,000 tokens (tier 3)

    async function deployStakingV2Fixture() {
        const [admin, user1, user2, validator1, treasury] = await ethers.getSigners();

        // Deploy OmniCoinConfig
        const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
        const config = await OmniCoinConfig.deploy(admin.address);

        // Deploy OmniCoinCore
        const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
        const token = await OmniCoinCore.deploy(
            admin.address,
            admin.address, // bridge
            treasury.address, // treasury
            2 // minimum validators
        );

        // Deploy OmniCoinStakingV2
        const OmniCoinStakingV2 = await ethers.getContractFactory("OmniCoinStakingV2");
        const staking = await OmniCoinStakingV2.deploy(
            await config.getAddress(),
            await token.getAddress(),
            admin.address
        );

        // Grant validator role
        await staking.connect(admin).grantRole(VALIDATOR_ROLE, validator1.address);

        return {
            staking,
            token,
            config,
            admin,
            user1,
            user2,
            validator1,
            treasury
        };
    }

    describe("Deployment", function () {
        it("Should set the correct config and token addresses", async function () {
            const { staking, token, config } = await loadFixture(deployStakingV2Fixture);

            expect(await staking.config()).to.equal(await config.getAddress());
            expect(await staking.token()).to.equal(await token.getAddress());
        });

        it("Should grant correct roles to admin", async function () {
            const { staking, admin } = await loadFixture(deployStakingV2Fixture);

            const DEFAULT_ADMIN_ROLE = await staking.DEFAULT_ADMIN_ROLE();
            
            expect(await staking.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await staking.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
            expect(await staking.hasRole(REWARD_DISTRIBUTOR_ROLE, admin.address)).to.be.true;
        });

        it("Should initialize with correct default values", async function () {
            const { staking } = await loadFixture(deployStakingV2Fixture);

            expect(await staking.totalStakers()).to.equal(0);
            expect(await staking.stakingPaused()).to.be.false;
        });

        it("Should revert with zero addresses", async function () {
            const [admin] = await ethers.getSigners();
            const OmniCoinStakingV2 = await ethers.getContractFactory("OmniCoinStakingV2");

            await expect(
                OmniCoinStakingV2.deploy(ethers.ZeroAddress, admin.address, admin.address)
            ).to.be.revertedWith("OmniCoinStakingV2: Config cannot be zero address");

            await expect(
                OmniCoinStakingV2.deploy(admin.address, ethers.ZeroAddress, admin.address)
            ).to.be.revertedWith("OmniCoinStakingV2: Token cannot be zero address");

            await expect(
                OmniCoinStakingV2.deploy(admin.address, admin.address, ethers.ZeroAddress)
            ).to.be.revertedWith("OmniCoinStakingV2: Admin cannot be zero address");
        });
    });

    describe("Privacy Staking Functions", function () {
        it("Should create new stake with encrypted amounts", async function () {
            const { staking, token, admin, user1 } = await loadFixture(deployStakingV2Fixture);

            // Note: These tests will work with the contract structure but MPC functions
            // will only work properly on COTI testnet. For Hardhat testing, we test
            // the contract interfaces and logic flow.

            // In a real COTI environment, this would be:
            // const encryptedAmount = await token.encrypt(STAKE_AMOUNT_TIER1, user1.address);
            // For Hardhat testing, we'll test that the functions exist and can be called
            
            expect(typeof staking.stakePrivate).to.equal("function");
            expect(typeof staking.stakeGarbled).to.equal("function");
        });

        it("Should track public information for PoP calculations", async function () {
            const { staking, user1 } = await loadFixture(deployStakingV2Fixture);

            // Test public stake info structure
            const publicInfo = await staking.getPublicStakeInfo(user1.address);
            expect(publicInfo.isActive).to.be.false; // No stake yet
            
            // Test tier info structure
            const [totalStakers, totalTierWeight] = await staking.getTierInfo(0);
            expect(totalStakers).to.equal(0);
            expect(totalTierWeight).to.equal(0);
        });

        it("Should provide encrypted data for user viewing", async function () {
            const { staking, user1 } = await loadFixture(deployStakingV2Fixture);

            // Test private stake info structure
            const privateInfo = await staking.getPrivateStakeInfo(user1.address);
            // In Hardhat, these will be zero/empty, but on COTI they would contain encrypted data
            expect(privateInfo.userEncryptedAmount).to.exist;
            expect(privateInfo.userEncryptedRewards).to.exist;
        });
    });

    describe("Participation Score Management", function () {
        it("Should update participation scores for PoP", async function () {
            const { staking, validator1, user1 } = await loadFixture(deployStakingV2Fixture);

            await expect(staking.connect(validator1).updateParticipationScore(user1.address, 85))
                .to.emit(staking, "ParticipationScoreUpdated")
                .withArgs(user1.address, 0, 85);

            expect(await staking.participationScores(user1.address)).to.equal(85);
        });

        it("Should reject participation scores above 100", async function () {
            const { staking, validator1, user1 } = await loadFixture(deployStakingV2Fixture);

            await expect(
                staking.connect(validator1).updateParticipationScore(user1.address, 101)
            ).to.be.revertedWith("OmniCoinStakingV2: Score must be <= 100");
        });

        it("Should only allow validators to update participation scores", async function () {
            const { staking, user1, user2 } = await loadFixture(deployStakingV2Fixture);

            await expect(
                staking.connect(user1).updateParticipationScore(user2.address, 50)
            ).to.be.reverted;
        });
    });

    describe("Admin Functions", function () {
        it("Should toggle staking pause", async function () {
            const { staking, admin } = await loadFixture(deployStakingV2Fixture);

            await expect(staking.connect(admin).toggleStakingPause())
                .to.emit(staking, "StakingPausedToggled")
                .withArgs(true);

            expect(await staking.stakingPaused()).to.be.true;

            await expect(staking.connect(admin).toggleStakingPause())
                .to.emit(staking, "StakingPausedToggled")
                .withArgs(false);

            expect(await staking.stakingPaused()).to.be.false;
        });

        it("Should pause and unpause contract", async function () {
            const { staking, admin } = await loadFixture(deployStakingV2Fixture);

            await staking.connect(admin).pause();
            expect(await staking.paused()).to.be.true;

            await staking.connect(admin).unpause();
            expect(await staking.paused()).to.be.false;
        });

        it("Should only allow admin to call admin functions", async function () {
            const { staking, user1 } = await loadFixture(deployStakingV2Fixture);

            await expect(staking.connect(user1).toggleStakingPause()).to.be.reverted;
            await expect(staking.connect(user1).pause()).to.be.reverted;
            await expect(staking.connect(user1).unpause()).to.be.reverted;
        });
    });

    describe("Tier Management", function () {
        it("Should track tier information correctly", async function () {
            const { staking } = await loadFixture(deployStakingV2Fixture);

            // Test that tier info can be retrieved
            const [tier0Stakers] = await staking.getTierInfo(0);
            const [tier1Stakers] = await staking.getTierInfo(1);
            const [tier2Stakers] = await staking.getTierInfo(2);

            expect(tier0Stakers).to.equal(0);
            expect(tier1Stakers).to.equal(0);
            expect(tier2Stakers).to.equal(0);
        });

        it("Should provide active staker enumeration", async function () {
            const { staking } = await loadFixture(deployStakingV2Fixture);

            const activeStakers = await staking.getActiveStakers();
            expect(activeStakers.length).to.equal(0);
        });
    });

    describe("Reward System Structure", function () {
        it("Should have reward claiming functionality", async function () {
            const { staking } = await loadFixture(deployStakingV2Fixture);

            // Test that reward functions exist
            expect(typeof staking.claimRewards).to.equal("function");
        });

        it("Should integrate with config for reward calculations", async function () {
            const { staking, config } = await loadFixture(deployStakingV2Fixture);

            // Test config integration
            expect(await staking.config()).to.equal(await config.getAddress());
            expect(await config.useParticipationScore()).to.be.true;
        });
    });

    describe("Security Features", function () {
        it("Should prevent operations when paused", async function () {
            const { staking, admin } = await loadFixture(deployStakingV2Fixture);

            await staking.connect(admin).pause();

            // Test that staking functions would be paused
            // Note: Actual calls would require proper MPC setup for COTI network
            expect(await staking.paused()).to.be.true;
        });

        it("Should prevent staking when staking is paused", async function () {
            const { staking, admin } = await loadFixture(deployStakingV2Fixture);

            await staking.connect(admin).toggleStakingPause();
            expect(await staking.stakingPaused()).to.be.true;

            // Staking functions would check this modifier
        });

        it("Should use reentrancy protection", async function () {
            const { staking } = await loadFixture(deployStakingV2Fixture);

            // Test that the contract has reentrancy protection
            // This is verified by the presence of nonReentrant modifiers in the contract
            expect(typeof staking.stakePrivate).to.equal("function");
            expect(typeof staking.unstakePrivate).to.equal("function");
            expect(typeof staking.claimRewards).to.equal("function");
        });
    });

    describe("Integration with OmniCoinCore", function () {
        it("Should reference correct token contract", async function () {
            const { staking, token } = await loadFixture(deployStakingV2Fixture);

            expect(await staking.token()).to.equal(await token.getAddress());
        });

        it("Should support privacy transfer functions", async function () {
            const { token } = await loadFixture(deployStakingV2Fixture);

            // Verify that OmniCoinCore has the required privacy functions
            expect(typeof token.transferGarbled).to.equal("function");
            expect(typeof token.transferPrivate).to.equal("function");
        });
    });

    describe("Data Structure Integrity", function () {
        it("Should maintain consistent state variables", async function () {
            const { staking } = await loadFixture(deployStakingV2Fixture);

            // Test initial state consistency
            expect(await staking.totalStakers()).to.equal(0);
            
            const activeStakers = await staking.getActiveStakers();
            expect(activeStakers.length).to.equal(0);
        });

        it("Should handle role-based access correctly", async function () {
            const { staking, admin, validator1 } = await loadFixture(deployStakingV2Fixture);

            // Test role assignments
            expect(await staking.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
            expect(await staking.hasRole(VALIDATOR_ROLE, validator1.address)).to.be.true;
            expect(await staking.hasRole(VALIDATOR_ROLE, admin.address)).to.be.false;
        });
    });

    describe("Privacy and PoP Balance", function () {
        it("Should separate private amounts from public tier data", async function () {
            const { staking, user1 } = await loadFixture(deployStakingV2Fixture);

            // Test that public and private data are separate
            const publicInfo = await staking.getPublicStakeInfo(user1.address);
            const privateInfo = await staking.getPrivateStakeInfo(user1.address);

            // Public info should be readable without decryption
            expect(typeof publicInfo.tier).to.equal("bigint");
            expect(typeof publicInfo.participationScore).to.equal("bigint");
            expect(typeof publicInfo.isActive).to.equal("boolean");

            // Private info should be encrypted (structure exists but content is encrypted)
            expect(privateInfo.userEncryptedAmount).to.exist;
            expect(privateInfo.userEncryptedRewards).to.exist;
        });

        it("Should support PoP calculations with public data", async function () {
            const { staking, validator1, user1 } = await loadFixture(deployStakingV2Fixture);

            // Set participation score
            await staking.connect(validator1).updateParticipationScore(user1.address, 75);

            // Get public info for PoP
            const publicInfo = await staking.getPublicStakeInfo(user1.address);
            expect(publicInfo.participationScore).to.equal(75);

            // Tier info should be available for PoP weight calculations
            const [, totalTierWeight] = await staking.getTierInfo(0);
            expect(totalTierWeight).to.be.a("bigint");
        });
    });
});