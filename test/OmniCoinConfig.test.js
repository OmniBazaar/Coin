const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinConfig", function () {
    let owner, user1, user2, treasury;
    let registry, omniCoin;
    let config;
    
    // Constants
    const CHAIN_ID_ETHEREUM = 1;
    const CHAIN_ID_BSC = 56;
    const CHAIN_ID_POLYGON = 137;
    
    // Default values
    const DEFAULT_EMISSION_RATE = 100;
    const DEFAULT_PROPOSAL_THRESHOLD = ethers.parseUnits("10000", 6);
    const DEFAULT_VOTING_PERIOD = 3 * 24 * 60 * 60; // 3 days
    const DEFAULT_QUORUM = ethers.parseUnits("100000", 6);
    const DEFAULT_PRIVACY_FEE_RATE = 100; // 1%
    const DEFAULT_PRIVACY_FEE_MULTIPLIER = 10;
    const DEFAULT_TOKEN_BRIDGE_FEE = ethers.parseUnits("10", 6);
    
    beforeEach(async function () {
        [owner, user1, user2, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        
        // Deploy OmniCoinConfig
        const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
        config = await OmniCoinConfig.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await config.waitForDeployment();
    });
    
    describe("Deployment and Initial Values", function () {
        it("Should set correct default values", async function () {
            expect(await config.owner()).to.equal(await owner.getAddress());
            expect(await config.emissionRate()).to.equal(DEFAULT_EMISSION_RATE);
            expect(await config.useParticipationScore()).to.be.true;
            expect(await config.proposalThreshold()).to.equal(DEFAULT_PROPOSAL_THRESHOLD);
            expect(await config.votingPeriod()).to.equal(DEFAULT_VOTING_PERIOD);
            expect(await config.quorum()).to.equal(DEFAULT_QUORUM);
            expect(await config.isTestnetMode()).to.be.false;
            expect(await config.privacyFeeRate()).to.equal(DEFAULT_PRIVACY_FEE_RATE);
            expect(await config.privacyFeeMultiplier()).to.equal(DEFAULT_PRIVACY_FEE_MULTIPLIER);
            expect(await config.privacyEnabled()).to.be.true;
            expect(await config.tokenBridgeFee()).to.equal(DEFAULT_TOKEN_BRIDGE_FEE);
        });
        
        it("Should initialize default staking tiers", async function () {
            // Check tier 0 (Bronze)
            const tier0 = await config.stakingTiers(0);
            expect(tier0.minAmount).to.equal(ethers.parseUnits("1000", 6));
            expect(tier0.maxAmount).to.equal(ethers.parseUnits("10000", 6));
            expect(tier0.rewardRate).to.equal(5); // 5% APY
            expect(tier0.lockPeriod).to.equal(30 * 24 * 60 * 60); // 30 days
            expect(tier0.penaltyRate).to.equal(10); // 10%
            
            // Check tier 1 (Silver)
            const tier1 = await config.stakingTiers(1);
            expect(tier1.minAmount).to.equal(ethers.parseUnits("10000", 6));
            expect(tier1.maxAmount).to.equal(ethers.parseUnits("100000", 6));
            expect(tier1.rewardRate).to.equal(10); // 10% APY
            expect(tier1.lockPeriod).to.equal(90 * 24 * 60 * 60); // 90 days
            expect(tier1.penaltyRate).to.equal(20); // 20%
            
            // Check tier 2 (Gold)
            const tier2 = await config.stakingTiers(2);
            expect(tier2.minAmount).to.equal(ethers.parseUnits("100000", 6));
            expect(tier2.maxAmount).to.equal(ethers.MaxUint256);
            expect(tier2.rewardRate).to.equal(20); // 20% APY
            expect(tier2.lockPeriod).to.equal(180 * 24 * 60 * 60); // 180 days
            expect(tier2.penaltyRate).to.equal(30); // 30%
        });
    });
    
    describe("Bridge Configuration", function () {
        it("Should add bridge configuration", async function () {
            const minAmount = ethers.parseUnits("100", 6);
            const maxAmount = ethers.parseUnits("100000", 6);
            const fee = ethers.parseUnits("1", 6);
            
            await expect(
                config.connect(owner).addBridgeConfig(
                    CHAIN_ID_ETHEREUM,
                    await user1.getAddress(), // mock token address
                    minAmount,
                    maxAmount,
                    fee
                )
            ).to.emit(config, "BridgeConfigAdded")
                .withArgs(CHAIN_ID_ETHEREUM, await user1.getAddress(), minAmount, maxAmount, fee);
            
            expect(await config.isBridgeSupported(CHAIN_ID_ETHEREUM)).to.be.true;
            
            const bridgeConfig = await config.getBridgeConfig(CHAIN_ID_ETHEREUM);
            expect(bridgeConfig.chainId).to.equal(CHAIN_ID_ETHEREUM);
            expect(bridgeConfig.token).to.equal(await user1.getAddress());
            expect(bridgeConfig.isActive).to.be.true;
            expect(bridgeConfig.minAmount).to.equal(minAmount);
            expect(bridgeConfig.maxAmount).to.equal(maxAmount);
            expect(bridgeConfig.fee).to.equal(fee);
        });
        
        it("Should not add bridge for current chain", async function () {
            const currentChainId = 31337; // Hardhat chain ID
            
            await expect(
                config.connect(owner).addBridgeConfig(
                    currentChainId,
                    await user1.getAddress(),
                    100,
                    1000,
                    10
                )
            ).to.be.revertedWithCustomError(config, "InvalidChainId");
        });
        
        it("Should not add bridge with zero address", async function () {
            await expect(
                config.connect(owner).addBridgeConfig(
                    CHAIN_ID_ETHEREUM,
                    ethers.ZeroAddress,
                    100,
                    1000,
                    10
                )
            ).to.be.revertedWithCustomError(config, "InvalidAmount");
        });
        
        it("Should not add bridge with invalid amounts", async function () {
            await expect(
                config.connect(owner).addBridgeConfig(
                    CHAIN_ID_ETHEREUM,
                    await user1.getAddress(),
                    1000, // min > max
                    100,
                    10
                )
            ).to.be.revertedWithCustomError(config, "InvalidAmount");
        });
        
        it("Should remove bridge configuration", async function () {
            // First add a bridge
            await config.connect(owner).addBridgeConfig(
                CHAIN_ID_BSC,
                await user1.getAddress(),
                100,
                1000,
                10
            );
            
            await expect(config.connect(owner).removeBridgeConfig(CHAIN_ID_BSC))
                .to.emit(config, "BridgeConfigRemoved")
                .withArgs(CHAIN_ID_BSC);
            
            expect(await config.isBridgeSupported(CHAIN_ID_BSC)).to.be.false;
        });
        
        it("Should handle multiple bridge configurations", async function () {
            await config.connect(owner).addBridgeConfig(
                CHAIN_ID_ETHEREUM,
                await user1.getAddress(),
                100,
                1000,
                10
            );
            
            await config.connect(owner).addBridgeConfig(
                CHAIN_ID_BSC,
                await user2.getAddress(),
                200,
                2000,
                20
            );
            
            expect(await config.isBridgeSupported(CHAIN_ID_ETHEREUM)).to.be.true;
            expect(await config.isBridgeSupported(CHAIN_ID_BSC)).to.be.true;
            expect(await config.isBridgeSupported(CHAIN_ID_POLYGON)).to.be.false;
        });
        
        it("Should revert for non-existent bridge config", async function () {
            await expect(
                config.getBridgeConfig(CHAIN_ID_POLYGON)
            ).to.be.revertedWithCustomError(config, "ConfigNotFound");
        });
    });
    
    describe("Staking Tier Management", function () {
        it("Should update staking tier", async function () {
            const tierId = 0;
            const newMinAmount = ethers.parseUnits("500", 6);
            const newMaxAmount = ethers.parseUnits("5000", 6);
            const newRewardRate = 3;
            const newLockPeriod = 15 * 24 * 60 * 60; // 15 days
            const newPenaltyRate = 5;
            
            await expect(
                config.connect(owner).updateStakingTier(
                    tierId,
                    newMinAmount,
                    newMaxAmount,
                    newRewardRate,
                    newLockPeriod,
                    newPenaltyRate
                )
            ).to.emit(config, "StakingTierUpdated")
                .withArgs(tierId, newMinAmount, newMaxAmount, newRewardRate, newLockPeriod, newPenaltyRate);
            
            const tier = await config.stakingTiers(tierId);
            expect(tier.minAmount).to.equal(newMinAmount);
            expect(tier.maxAmount).to.equal(newMaxAmount);
            expect(tier.rewardRate).to.equal(newRewardRate);
            expect(tier.lockPeriod).to.equal(newLockPeriod);
            expect(tier.penaltyRate).to.equal(newPenaltyRate);
        });
        
        it("Should revert for invalid tier ID", async function () {
            await expect(
                config.connect(owner).updateStakingTier(
                    5, // Non-existent tier
                    100,
                    1000,
                    5,
                    30 * 24 * 60 * 60,
                    10
                )
            ).to.be.revertedWithCustomError(config, "TierNotFound");
        });
        
        it("Should get correct staking tier for amount", async function () {
            // Test tier 0 (1,000 - 10,000)
            const tier0Amount = ethers.parseUnits("5000", 6);
            const tier0 = await config.getStakingTier(tier0Amount);
            expect(tier0.rewardRate).to.equal(5);
            
            // Test tier 1 (10,000 - 100,000)
            const tier1Amount = ethers.parseUnits("50000", 6);
            const tier1 = await config.getStakingTier(tier1Amount);
            expect(tier1.rewardRate).to.equal(10);
            
            // Test tier 2 (100,000+)
            const tier2Amount = ethers.parseUnits("500000", 6);
            const tier2 = await config.getStakingTier(tier2Amount);
            expect(tier2.rewardRate).to.equal(20);
        });
        
        it("Should revert for amount below minimum tier", async function () {
            const tooSmallAmount = ethers.parseUnits("500", 6); // Below tier 0 minimum
            
            await expect(
                config.getStakingTier(tooSmallAmount)
            ).to.be.revertedWithCustomError(config, "TierNotFound");
        });
    });
    
    describe("Governance Parameters", function () {
        it("Should update emission rate", async function () {
            const newRate = 200;
            
            await expect(config.connect(owner).setEmissionRate(newRate))
                .to.emit(config, "EmissionRateUpdated")
                .withArgs(DEFAULT_EMISSION_RATE, newRate);
            
            expect(await config.emissionRate()).to.equal(newRate);
        });
        
        it("Should toggle participation score", async function () {
            expect(await config.useParticipationScore()).to.be.true;
            
            await expect(config.connect(owner).toggleParticipationScore())
                .to.emit(config, "ParticipationScoreToggled")
                .withArgs(false);
            
            expect(await config.useParticipationScore()).to.be.false;
            
            // Toggle back
            await config.connect(owner).toggleParticipationScore();
            expect(await config.useParticipationScore()).to.be.true;
        });
        
        it("Should update proposal threshold", async function () {
            const newThreshold = ethers.parseUnits("5000", 6);
            
            await expect(config.connect(owner).setProposalThreshold(newThreshold))
                .to.emit(config, "ProposalThresholdUpdated")
                .withArgs(DEFAULT_PROPOSAL_THRESHOLD, newThreshold);
            
            expect(await config.proposalThreshold()).to.equal(newThreshold);
        });
        
        it("Should update voting period", async function () {
            const newPeriod = 7 * 24 * 60 * 60; // 7 days
            
            await expect(config.connect(owner).setVotingPeriod(newPeriod))
                .to.emit(config, "VotingPeriodUpdated")
                .withArgs(DEFAULT_VOTING_PERIOD, newPeriod);
            
            expect(await config.votingPeriod()).to.equal(newPeriod);
        });
        
        it("Should update quorum", async function () {
            const newQuorum = ethers.parseUnits("50000", 6);
            
            await expect(config.connect(owner).setQuorum(newQuorum))
                .to.emit(config, "QuorumUpdated")
                .withArgs(DEFAULT_QUORUM, newQuorum);
            
            expect(await config.quorum()).to.equal(newQuorum);
        });
        
        it("Should toggle testnet mode", async function () {
            expect(await config.isTestnetMode()).to.be.false;
            
            await expect(config.connect(owner).toggleTestnetMode())
                .to.emit(config, "TestnetModeToggled")
                .withArgs(true);
            
            expect(await config.isTestnetMode()).to.be.true;
        });
    });
    
    describe("Privacy Configuration", function () {
        it("Should update privacy fee rate", async function () {
            const newRate = 200; // 2%
            
            await expect(config.connect(owner).setPrivacyFeeRate(newRate))
                .to.emit(config, "PrivacyFeeRateUpdated")
                .withArgs(DEFAULT_PRIVACY_FEE_RATE, newRate);
            
            expect(await config.privacyFeeRate()).to.equal(newRate);
        });
        
        it("Should not allow privacy fee rate above 10%", async function () {
            await expect(
                config.connect(owner).setPrivacyFeeRate(1001) // 10.01%
            ).to.be.revertedWithCustomError(config, "InvalidRate");
        });
        
        it("Should update privacy fee multiplier", async function () {
            const newMultiplier = 20;
            
            await expect(config.connect(owner).setPrivacyFeeMultiplier(newMultiplier))
                .to.emit(config, "PrivacyFeeMultiplierUpdated")
                .withArgs(DEFAULT_PRIVACY_FEE_MULTIPLIER, newMultiplier);
            
            expect(await config.privacyFeeMultiplier()).to.equal(newMultiplier);
        });
        
        it("Should not allow invalid privacy fee multiplier", async function () {
            await expect(
                config.connect(owner).setPrivacyFeeMultiplier(0)
            ).to.be.revertedWithCustomError(config, "InvalidRate");
            
            await expect(
                config.connect(owner).setPrivacyFeeMultiplier(101)
            ).to.be.revertedWithCustomError(config, "InvalidRate");
        });
        
        it("Should toggle privacy", async function () {
            expect(await config.privacyEnabled()).to.be.true;
            
            await expect(config.connect(owner).togglePrivacy())
                .to.emit(config, "PrivacyToggled")
                .withArgs(false);
            
            expect(await config.privacyEnabled()).to.be.false;
        });
        
        it("Should update token bridge fee", async function () {
            const newFee = ethers.parseUnits("5", 6);
            
            await expect(config.connect(owner).setTokenBridgeFee(newFee))
                .to.emit(config, "TokenBridgeFeeUpdated")
                .withArgs(DEFAULT_TOKEN_BRIDGE_FEE, newFee);
            
            expect(await config.tokenBridgeFee()).to.equal(newFee);
        });
        
        it("Should get all privacy config", async function () {
            const privacyConfig = await config.getPrivacyConfig();
            
            expect(privacyConfig.feeRate).to.equal(DEFAULT_PRIVACY_FEE_RATE);
            expect(privacyConfig.feeMultiplier).to.equal(DEFAULT_PRIVACY_FEE_MULTIPLIER);
            expect(privacyConfig.enabled).to.be.true;
            expect(privacyConfig.bridgeFee).to.equal(DEFAULT_TOKEN_BRIDGE_FEE);
        });
    });
    
    describe("Access Control", function () {
        it("Should only allow owner to add bridge config", async function () {
            await expect(
                config.connect(user1).addBridgeConfig(
                    CHAIN_ID_ETHEREUM,
                    await user1.getAddress(),
                    100,
                    1000,
                    10
                )
            ).to.be.revertedWithCustomError(config, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to update staking tier", async function () {
            await expect(
                config.connect(user1).updateStakingTier(0, 100, 1000, 5, 30 * 24 * 60 * 60, 10)
            ).to.be.revertedWithCustomError(config, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to set emission rate", async function () {
            await expect(
                config.connect(user1).setEmissionRate(200)
            ).to.be.revertedWithCustomError(config, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to toggle privacy", async function () {
            await expect(
                config.connect(user1).togglePrivacy()
            ).to.be.revertedWithCustomError(config, "OwnableUnauthorizedAccount");
        });
    });
});