const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinValidator", function () {
    let owner, validator1, validator2, validator3, validator4, user, treasury;
    let registry, omniCoin, privateOmniCoin;
    let validatorContract;
    
    // Constants
    const MIN_STAKE = ethers.parseUnits("1000", 6);
    const REWARD_RATE = 100; // 1%
    const REWARD_PERIOD = 24 * 60 * 60; // 1 day
    const MAX_VALIDATORS = 100;
    
    beforeEach(async function () {
        [owner, validator1, validator2, validator3, validator4, user, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test
        const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        privateOmniCoin = await StandardERC20Test.deploy();
        await privateOmniCoin.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        
        // Deploy OmniCoinValidator
        const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
        validatorContract = await OmniCoinValidator.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await validatorContract.waitForDeployment();
        
        // Fund potential validators
        const fundAmount = ethers.parseUnits("10000", 6);
        await omniCoin.mint(await validator1.getAddress(), fundAmount);
        await omniCoin.mint(await validator2.getAddress(), fundAmount);
        await omniCoin.mint(await validator3.getAddress(), fundAmount);
        await privateOmniCoin.mint(await validator4.getAddress(), fundAmount);
        
        // Fund validator contract for rewards
        await omniCoin.mint(await validatorContract.getAddress(), ethers.parseUnits("100000", 6));
        await privateOmniCoin.mint(await validatorContract.getAddress(), ethers.parseUnits("100000", 6));
        
        // Approve validator contract
        await omniCoin.connect(validator1).approve(await validatorContract.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(validator2).approve(await validatorContract.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(validator3).approve(await validatorContract.getAddress(), ethers.MaxUint256);
        await privateOmniCoin.connect(validator4).approve(await validatorContract.getAddress(), ethers.MaxUint256);
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await validatorContract.owner()).to.equal(await owner.getAddress());
            expect(await validatorContract.rewardRate()).to.equal(REWARD_RATE);
            expect(await validatorContract.rewardPeriod()).to.equal(REWARD_PERIOD);
            expect(await validatorContract.minStake()).to.equal(MIN_STAKE);
            expect(await validatorContract.maxValidators()).to.equal(MAX_VALIDATORS);
        });
        
        it("Should update reward rate", async function () {
            const newRate = 200; // 2%
            
            await expect(validatorContract.connect(owner).setRewardRate(newRate))
                .to.emit(validatorContract, "RewardRateUpdated")
                .withArgs(REWARD_RATE, newRate);
            
            expect(await validatorContract.rewardRate()).to.equal(newRate);
        });
        
        it("Should update reward period", async function () {
            const newPeriod = 12 * 60 * 60; // 12 hours
            
            await expect(validatorContract.connect(owner).setRewardPeriod(newPeriod))
                .to.emit(validatorContract, "RewardPeriodUpdated")
                .withArgs(REWARD_PERIOD, newPeriod);
            
            expect(await validatorContract.rewardPeriod()).to.equal(newPeriod);
        });
        
        it("Should update minimum stake", async function () {
            const newMinStake = ethers.parseUnits("2000", 6);
            
            await expect(validatorContract.connect(owner).setMinStake(newMinStake))
                .to.emit(validatorContract, "MinStakeUpdated")
                .withArgs(MIN_STAKE, newMinStake);
            
            expect(await validatorContract.minStake()).to.equal(newMinStake);
        });
        
        it("Should update maximum validators", async function () {
            const newMax = 50;
            
            await expect(validatorContract.connect(owner).setMaxValidators(newMax))
                .to.emit(validatorContract, "MaxValidatorsUpdated")
                .withArgs(MAX_VALIDATORS, newMax);
            
            expect(await validatorContract.maxValidators()).to.equal(newMax);
        });
    });
    
    describe("Validator Registration", function () {
        it("Should register validator with public token", async function () {
            await expect(validatorContract.connect(validator1).registerValidator(false))
                .to.emit(validatorContract, "ValidatorRegistered")
                .withArgs(await validator1.getAddress(), 0);
            
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.isActive).to.be.true;
            expect(validatorInfo.usePrivacy).to.be.false;
            expect(validatorInfo.stakeAmount).to.equal(0);
        });
        
        it("Should register validator with private token", async function () {
            await expect(validatorContract.connect(validator4).registerValidator(true))
                .to.emit(validatorContract, "ValidatorRegistered")
                .withArgs(await validator4.getAddress(), 0);
            
            const validatorInfo = await validatorContract.getValidator(await validator4.getAddress());
            expect(validatorInfo.isActive).to.be.true;
            expect(validatorInfo.usePrivacy).to.be.true;
        });
        
        it("Should not register already registered validator", async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            
            await expect(
                validatorContract.connect(validator1).registerValidator(false)
            ).to.be.revertedWithCustomError(validatorContract, "AlreadyRegistered");
        });
        
        it("Should not register validator with insufficient balance", async function () {
            await expect(
                validatorContract.connect(user).registerValidator(false)
            ).to.be.revertedWithCustomError(validatorContract, "InsufficientBalance");
        });
        
        it("Should unregister validator", async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            
            await expect(validatorContract.connect(validator1).unregisterValidator())
                .to.emit(validatorContract, "ValidatorUnregistered")
                .withArgs(await validator1.getAddress());
            
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.isActive).to.be.false;
        });
        
        it("Should not unregister validator with stake", async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            await validatorContract.connect(validator1).stake(MIN_STAKE);
            
            await expect(
                validatorContract.connect(validator1).unregisterValidator()
            ).to.be.revertedWithCustomError(validatorContract, "StillHasStake");
        });
    });
    
    describe("Staking", function () {
        beforeEach(async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            await validatorContract.connect(validator2).registerValidator(false);
            await validatorContract.connect(validator4).registerValidator(true);
        });
        
        it("Should stake tokens for validator", async function () {
            const stakeAmount = ethers.parseUnits("2000", 6);
            const balanceBefore = await omniCoin.balanceOf(await validator1.getAddress());
            
            await expect(validatorContract.connect(validator1).stake(stakeAmount))
                .to.emit(validatorContract, "ValidatorStaked")
                .withArgs(await validator1.getAddress(), stakeAmount);
            
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.stakeAmount).to.equal(stakeAmount);
            
            expect(await omniCoin.balanceOf(await validator1.getAddress()))
                .to.equal(balanceBefore - stakeAmount);
                
            // Check active set
            const activeSet = await validatorContract.getActiveSet();
            expect(activeSet.totalStake).to.equal(stakeAmount);
            expect(activeSet.validatorList).to.include(await validator1.getAddress());
        });
        
        it("Should stake private tokens for privacy validator", async function () {
            const stakeAmount = ethers.parseUnits("2000", 6);
            
            await expect(validatorContract.connect(validator4).stake(stakeAmount))
                .to.emit(validatorContract, "ValidatorStaked")
                .withArgs(await validator4.getAddress(), stakeAmount);
            
            const validatorInfo = await validatorContract.getValidator(await validator4.getAddress());
            expect(validatorInfo.stakeAmount).to.equal(stakeAmount);
            expect(validatorInfo.usePrivacy).to.be.true;
        });
        
        it("Should not stake zero amount", async function () {
            await expect(
                validatorContract.connect(validator1).stake(0)
            ).to.be.revertedWithCustomError(validatorContract, "InvalidAmount");
        });
        
        it("Should not stake more than balance", async function () {
            const tooMuch = ethers.parseUnits("20000", 6);
            
            await expect(
                validatorContract.connect(validator1).stake(tooMuch)
            ).to.be.revertedWithCustomError(validatorContract, "InsufficientBalance");
        });
        
        it("Should handle multiple stakes", async function () {
            const stake1 = ethers.parseUnits("1000", 6);
            const stake2 = ethers.parseUnits("500", 6);
            
            await validatorContract.connect(validator1).stake(stake1);
            await validatorContract.connect(validator1).stake(stake2);
            
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.stakeAmount).to.equal(stake1 + stake2);
        });
    });
    
    describe("Unstaking", function () {
        beforeEach(async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            await validatorContract.connect(validator1).stake(ethers.parseUnits("3000", 6));
        });
        
        it("Should unstake tokens", async function () {
            const unstakeAmount = ethers.parseUnits("1000", 6);
            const balanceBefore = await omniCoin.balanceOf(await validator1.getAddress());
            
            await expect(validatorContract.connect(validator1).unstake(unstakeAmount))
                .to.emit(validatorContract, "ValidatorUnstaked")
                .withArgs(await validator1.getAddress(), unstakeAmount);
            
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.stakeAmount).to.equal(ethers.parseUnits("2000", 6));
            
            expect(await omniCoin.balanceOf(await validator1.getAddress()))
                .to.equal(balanceBefore + unstakeAmount);
        });
        
        it("Should remove from active set if below minimum", async function () {
            const unstakeAmount = ethers.parseUnits("2500", 6); // Leave only 500
            
            await validatorContract.connect(validator1).unstake(unstakeAmount);
            
            const activeSet = await validatorContract.getActiveSet();
            expect(activeSet.validatorList).to.not.include(await validator1.getAddress());
        });
        
        it("Should not unstake more than staked", async function () {
            await expect(
                validatorContract.connect(validator1).unstake(ethers.parseUnits("4000", 6))
            ).to.be.revertedWithCustomError(validatorContract, "InsufficientStakeAmount");
        });
        
        it("Should not unstake zero amount", async function () {
            await expect(
                validatorContract.connect(validator1).unstake(0)
            ).to.be.revertedWithCustomError(validatorContract, "InvalidAmount");
        });
    });
    
    describe("Rewards", function () {
        beforeEach(async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            await validatorContract.connect(validator2).registerValidator(false);
            
            await validatorContract.connect(validator1).stake(ethers.parseUnits("2000", 6));
            await validatorContract.connect(validator2).stake(ethers.parseUnits("5000", 6));
        });
        
        it("Should calculate rewards correctly", async function () {
            // Fast forward 1 day
            await ethers.provider.send("evm_increaseTime", [REWARD_PERIOD]);
            await ethers.provider.send("evm_mine");
            
            const rewards1 = await validatorContract.calculateRewards(await validator1.getAddress());
            const rewards2 = await validatorContract.calculateRewards(await validator2.getAddress());
            
            // 1% of 2000 = 20 tokens
            expect(rewards1).to.equal(ethers.parseUnits("20", 6));
            // 1% of 5000 = 50 tokens
            expect(rewards2).to.equal(ethers.parseUnits("50", 6));
        });
        
        it("Should claim rewards", async function () {
            // Fast forward 2 days
            await ethers.provider.send("evm_increaseTime", [REWARD_PERIOD * 2]);
            await ethers.provider.send("evm_mine");
            
            const balanceBefore = await omniCoin.balanceOf(await validator1.getAddress());
            const expectedRewards = ethers.parseUnits("40", 6); // 2 days * 1% * 2000
            
            await expect(validatorContract.connect(validator1).claimRewards())
                .to.emit(validatorContract, "RewardsClaimed")
                .withArgs(await validator1.getAddress(), expectedRewards);
            
            expect(await omniCoin.balanceOf(await validator1.getAddress()))
                .to.equal(balanceBefore + expectedRewards);
            
            // Check rewards reset
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.accumulatedRewards).to.equal(0);
        });
        
        it("Should accumulate rewards on stake", async function () {
            // Fast forward 1 day
            await ethers.provider.send("evm_increaseTime", [REWARD_PERIOD]);
            await ethers.provider.send("evm_mine");
            
            // Stake more - should accumulate pending rewards
            await validatorContract.connect(validator1).stake(ethers.parseUnits("1000", 6));
            
            const validatorInfo = await validatorContract.getValidator(await validator1.getAddress());
            expect(validatorInfo.accumulatedRewards).to.equal(ethers.parseUnits("20", 6));
        });
        
        it("Should not claim zero rewards", async function () {
            await expect(
                validatorContract.connect(validator1).claimRewards()
            ).to.be.revertedWithCustomError(validatorContract, "NoRewardsAvailable");
        });
        
        it("Should handle rewards for multiple periods", async function () {
            // Fast forward 5 days
            await ethers.provider.send("evm_increaseTime", [REWARD_PERIOD * 5]);
            await ethers.provider.send("evm_mine");
            
            const rewards = await validatorContract.calculateRewards(await validator1.getAddress());
            expect(rewards).to.equal(ethers.parseUnits("100", 6)); // 5 days * 1% * 2000
        });
    });
    
    describe("Active Set Management", function () {
        it("Should manage active validator set", async function () {
            // Register and stake multiple validators
            await validatorContract.connect(validator1).registerValidator(false);
            await validatorContract.connect(validator2).registerValidator(false);
            await validatorContract.connect(validator3).registerValidator(false);
            
            await validatorContract.connect(validator1).stake(ethers.parseUnits("2000", 6));
            await validatorContract.connect(validator2).stake(ethers.parseUnits("3000", 6));
            await validatorContract.connect(validator3).stake(ethers.parseUnits("1500", 6));
            
            const activeSet = await validatorContract.getActiveSet();
            expect(activeSet.validatorList.length).to.equal(3);
            expect(activeSet.totalStake).to.equal(ethers.parseUnits("6500", 6));
            expect(activeSet.validatorList).to.include(await validator1.getAddress());
            expect(activeSet.validatorList).to.include(await validator2.getAddress());
            expect(activeSet.validatorList).to.include(await validator3.getAddress());
        });
        
        it("Should respect maximum validators limit", async function () {
            // Set low limit for testing
            await validatorContract.connect(owner).setMaxValidators(2);
            
            await validatorContract.connect(validator1).registerValidator(false);
            await validatorContract.connect(validator2).registerValidator(false);
            await validatorContract.connect(validator3).registerValidator(false);
            
            await validatorContract.connect(validator1).stake(MIN_STAKE);
            await validatorContract.connect(validator2).stake(MIN_STAKE);
            
            // Third validator stakes but shouldn't be added to active set
            await validatorContract.connect(validator3).stake(MIN_STAKE);
            
            const activeSet = await validatorContract.getActiveSet();
            expect(activeSet.validatorList.length).to.equal(2);
        });
    });
    
    describe("Access Control", function () {
        it("Should only allow owner to set reward rate", async function () {
            await expect(
                validatorContract.connect(validator1).setRewardRate(200)
            ).to.be.revertedWithCustomError(validatorContract, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to set reward period", async function () {
            await expect(
                validatorContract.connect(validator1).setRewardPeriod(12 * 60 * 60)
            ).to.be.revertedWithCustomError(validatorContract, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to set minimum stake", async function () {
            await expect(
                validatorContract.connect(validator1).setMinStake(ethers.parseUnits("2000", 6))
            ).to.be.revertedWithCustomError(validatorContract, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow registered validators to stake", async function () {
            await expect(
                validatorContract.connect(validator1).stake(MIN_STAKE)
            ).to.be.revertedWithCustomError(validatorContract, "NotActiveValidator");
        });
    });
    
    describe("Edge Cases", function () {
        it("Should handle validator with no stake calculating rewards", async function () {
            await validatorContract.connect(validator1).registerValidator(false);
            
            const rewards = await validatorContract.calculateRewards(await validator1.getAddress());
            expect(rewards).to.equal(0);
        });
        
        it("Should handle inactive validator calculating rewards", async function () {
            const rewards = await validatorContract.calculateRewards(await user.getAddress());
            expect(rewards).to.equal(0);
        });
        
        it("Should get validator info for non-existent validator", async function () {
            const info = await validatorContract.getValidator(await user.getAddress());
            expect(info.isActive).to.be.false;
            expect(info.stakeAmount).to.equal(0);
        });
    });
});