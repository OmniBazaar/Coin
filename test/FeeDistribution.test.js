const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("FeeDistribution", function () {
    let owner, treasury, validator1, validator2, validator3, staker1, staker2, user;
    let registry, omniCoin, privateOmniCoin, validatorContract;
    let feeDistribution;
    
    // Constants
    const TREASURY_SHARE = 2000; // 20%
    const VALIDATOR_SHARE = 3000; // 30%
    const STAKING_SHARE = 5000; // 50%
    const TOTAL_BASIS_POINTS = 10000;
    
    beforeEach(async function () {
        [owner, treasury, validator1, validator2, validator3, staker1, staker2, user] = await ethers.getSigners();
        
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
        
        // Deploy actual OmniCoinValidator (which handles staking)
        const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
        validatorContract = await OmniCoinValidator.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await validatorContract.waitForDeployment();
        
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
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_VALIDATOR")),
            await validatorContract.getAddress()
        );
        // For now, also register as STAKING for compatibility
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("STAKING")),
            await validatorContract.getAddress()
        );
        
        // Deploy FeeDistribution
        const FeeDistribution = await ethers.getContractFactory("FeeDistribution");
        feeDistribution = await FeeDistribution.deploy(
            await mockRegistry.getAddress(),
            await owner.getAddress()
        );
        await feeDistribution.waitForDeployment();
        
        // Setup validators
        await feeDistribution.connect(owner).addValidator(await validator1.getAddress());
        await feeDistribution.connect(owner).addValidator(await validator2.getAddress());
        await feeDistribution.connect(owner).addValidator(await validator3.getAddress());
        
        // Setup stakers in mock staking
        await mockStaking.setStake(await staker1.getAddress(), ethers.parseUnits("1000", 6));
        await mockStaking.setStake(await staker2.getAddress(), ethers.parseUnits("2000", 6));
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await feeDistribution.owner()).to.equal(await owner.getAddress());
            expect(await feeDistribution.treasuryShare()).to.equal(TREASURY_SHARE);
            expect(await feeDistribution.validatorShare()).to.equal(VALIDATOR_SHARE);
            expect(await feeDistribution.stakingShare()).to.equal(STAKING_SHARE);
        });
        
        it("Should update distribution shares", async function () {
            const newTreasuryShare = 1500; // 15%
            const newValidatorShare = 3500; // 35%
            const newStakingShare = 5000; // 50%
            
            await expect(
                feeDistribution.connect(owner).updateDistributionShares(
                    newTreasuryShare,
                    newValidatorShare,
                    newStakingShare
                )
            ).to.emit(feeDistribution, "DistributionSharesUpdated")
                .withArgs(newTreasuryShare, newValidatorShare, newStakingShare);
            
            expect(await feeDistribution.treasuryShare()).to.equal(newTreasuryShare);
            expect(await feeDistribution.validatorShare()).to.equal(newValidatorShare);
            expect(await feeDistribution.stakingShare()).to.equal(newStakingShare);
        });
        
        it("Should reject invalid share configuration", async function () {
            await expect(
                feeDistribution.connect(owner).updateDistributionShares(
                    5000,
                    3000,
                    3000 // Total > 10000
                )
            ).to.be.revertedWithCustomError(feeDistribution, "InvalidShares");
        });
    });
    
    describe("Validator Management", function () {
        it("Should add validator", async function () {
            const newValidator = await user.getAddress();
            
            await expect(feeDistribution.connect(owner).addValidator(newValidator))
                .to.emit(feeDistribution, "ValidatorAdded")
                .withArgs(newValidator);
            
            expect(await feeDistribution.isValidator(newValidator)).to.be.true;
            expect(await feeDistribution.validatorCount()).to.equal(4);
        });
        
        it("Should remove validator", async function () {
            await expect(
                feeDistribution.connect(owner).removeValidator(await validator3.getAddress())
            ).to.emit(feeDistribution, "ValidatorRemoved")
                .withArgs(await validator3.getAddress());
            
            expect(await feeDistribution.isValidator(await validator3.getAddress())).to.be.false;
            expect(await feeDistribution.validatorCount()).to.equal(2);
        });
        
        it("Should not add duplicate validator", async function () {
            await expect(
                feeDistribution.connect(owner).addValidator(await validator1.getAddress())
            ).to.be.revertedWithCustomError(feeDistribution, "AlreadyValidator");
        });
    });
    
    describe("Fee Distribution", function () {
        beforeEach(async function () {
            // Fund fee distribution contract
            const feeAmount = ethers.parseUnits("1000", 6);
            await mockOmniCoin.mint(await feeDistribution.getAddress(), feeAmount);
        });
        
        it("Should distribute fees according to shares", async function () {
            const totalFees = ethers.parseUnits("1000", 6);
            
            const expectedTreasury = (totalFees * BigInt(TREASURY_SHARE)) / BigInt(TOTAL_BASIS_POINTS);
            const expectedValidators = (totalFees * BigInt(VALIDATOR_SHARE)) / BigInt(TOTAL_BASIS_POINTS);
            const expectedStaking = (totalFees * BigInt(STAKING_SHARE)) / BigInt(TOTAL_BASIS_POINTS);
            
            const treasuryBalanceBefore = await mockOmniCoin.balanceOf(await treasury.getAddress());
            
            await expect(
                feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress())
            ).to.emit(feeDistribution, "FeesDistributed")
                .withArgs(
                    await mockOmniCoin.getAddress(),
                    totalFees,
                    expectedTreasury,
                    expectedValidators,
                    expectedStaking
                );
            
            // Check treasury received its share
            expect(await mockOmniCoin.balanceOf(await treasury.getAddress()))
                .to.equal(treasuryBalanceBefore + expectedTreasury);
            
            // Check validators received equal shares
            const perValidatorAmount = expectedValidators / 3n;
            expect(await feeDistribution.pendingRewards(
                await validator1.getAddress(),
                await mockOmniCoin.getAddress()
            )).to.equal(perValidatorAmount);
            
            // Check staking pool received its share
            expect(await feeDistribution.stakingPoolBalance(await mockOmniCoin.getAddress()))
                .to.equal(expectedStaking);
        });
        
        it("Should handle multiple token distributions", async function () {
            // Fund with USDC too
            await mockPrivateOmniCoin.mint(
                await feeDistribution.getAddress(),
                ethers.parseUnits("500", 6)
            );
            
            // Distribute both tokens
            await feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress());
            await feeDistribution.connect(owner).distributeFees(await mockPrivateOmniCoin.getAddress());
            
            // Check both balances updated
            expect(await feeDistribution.totalDistributed(await mockOmniCoin.getAddress()))
                .to.equal(ethers.parseUnits("1000", 6));
            expect(await feeDistribution.totalDistributed(await mockPrivateOmniCoin.getAddress()))
                .to.equal(ethers.parseUnits("500", 6));
        });
        
        it("Should not distribute if no fees available", async function () {
            // Distribute once to empty the contract
            await feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress());
            
            // Try to distribute again
            await expect(
                feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress())
            ).to.be.revertedWithCustomError(feeDistribution, "NoFeesToDistribute");
        });
    });
    
    describe("Validator Rewards", function () {
        beforeEach(async function () {
            // Distribute fees to create pending rewards
            await mockOmniCoin.mint(await feeDistribution.getAddress(), ethers.parseUnits("900", 6));
            await feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress());
        });
        
        it("Should allow validators to claim rewards", async function () {
            const pendingAmount = await feeDistribution.pendingRewards(
                await validator1.getAddress(),
                await mockOmniCoin.getAddress()
            );
            
            const balanceBefore = await mockOmniCoin.balanceOf(await validator1.getAddress());
            
            await expect(
                feeDistribution.connect(validator1).claimValidatorRewards(await mockOmniCoin.getAddress())
            ).to.emit(feeDistribution, "ValidatorRewardsClaimed")
                .withArgs(await validator1.getAddress(), await mockOmniCoin.getAddress(), pendingAmount);
            
            expect(await mockOmniCoin.balanceOf(await validator1.getAddress()))
                .to.equal(balanceBefore + pendingAmount);
            
            // Check pending rewards reset
            expect(await feeDistribution.pendingRewards(
                await validator1.getAddress(),
                await mockOmniCoin.getAddress()
            )).to.equal(0);
        });
        
        it("Should claim multiple token rewards", async function () {
            // Add PrivateOmniCoin rewards
            await mockPrivateOmniCoin.mint(await feeDistribution.getAddress(), ethers.parseUnits("300", 6));
            await feeDistribution.connect(owner).distributeFees(await mockPrivateOmniCoin.getAddress());
            
            // Claim all rewards
            await feeDistribution.connect(validator1).claimAllValidatorRewards();
            
            // Check both tokens were claimed
            expect(await feeDistribution.pendingRewards(
                await validator1.getAddress(),
                await mockOmniCoin.getAddress()
            )).to.equal(0);
            expect(await feeDistribution.pendingRewards(
                await validator1.getAddress(),
                await mockPrivateOmniCoin.getAddress()
            )).to.equal(0);
        });
        
        it("Should not allow non-validators to claim", async function () {
            await expect(
                feeDistribution.connect(user).claimValidatorRewards(await mockOmniCoin.getAddress())
            ).to.be.revertedWithCustomError(feeDistribution, "NotValidator");
        });
    });
    
    describe("Staking Rewards", function () {
        beforeEach(async function () {
            // Distribute fees to fill staking pool
            await mockOmniCoin.mint(await feeDistribution.getAddress(), ethers.parseUnits("1000", 6));
            await feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress());
        });
        
        it("Should calculate staking rewards proportionally", async function () {
            // Total staked: 3000 (1000 + 2000)
            // Staking pool: 500 tokens (50% of 1000)
            // staker1 share: 1000/3000 = 33.33%
            // staker2 share: 2000/3000 = 66.67%
            
            const stakingPool = await feeDistribution.stakingPoolBalance(await mockOmniCoin.getAddress());
            const staker1Stake = ethers.parseUnits("1000", 6);
            const staker2Stake = ethers.parseUnits("2000", 6);
            const totalStake = staker1Stake + staker2Stake;
            
            const staker1Rewards = await feeDistribution.calculateStakingRewards(
                await staker1.getAddress(),
                await mockOmniCoin.getAddress()
            );
            const staker2Rewards = await feeDistribution.calculateStakingRewards(
                await staker2.getAddress(),
                await mockOmniCoin.getAddress()
            );
            
            expect(staker1Rewards).to.equal((stakingPool * staker1Stake) / totalStake);
            expect(staker2Rewards).to.equal((stakingPool * staker2Stake) / totalStake);
        });
        
        it("Should distribute staking rewards", async function () {
            const staker1BalanceBefore = await mockOmniCoin.balanceOf(await staker1.getAddress());
            const staker1Rewards = await feeDistribution.calculateStakingRewards(
                await staker1.getAddress(),
                await mockOmniCoin.getAddress()
            );
            
            await expect(
                feeDistribution.connect(owner).distributeStakingRewards(await mockOmniCoin.getAddress())
            ).to.emit(feeDistribution, "StakingRewardsDistributed")
                .withArgs(await mockOmniCoin.getAddress(), await feeDistribution.stakingPoolBalance(await mockOmniCoin.getAddress()));
            
            // Check staker received rewards
            expect(await mockOmniCoin.balanceOf(await staker1.getAddress()))
                .to.be.closeTo(staker1BalanceBefore + staker1Rewards, 10); // Allow small rounding difference
            
            // Check pool emptied
            expect(await feeDistribution.stakingPoolBalance(await mockOmniCoin.getAddress()))
                .to.equal(0);
        });
    });
    
    describe("Fee Collection", function () {
        it("Should collect fees from various sources", async function () {
            const feeAmount = ethers.parseUnits("100", 6);
            
            // Mint and approve
            await mockOmniCoin.mint(await user.getAddress(), feeAmount);
            await mockOmniCoin.connect(user).approve(await feeDistribution.getAddress(), feeAmount);
            
            await expect(
                feeDistribution.connect(user).collectFee(
                    await mockOmniCoin.getAddress(),
                    feeAmount,
                    "Trading fee"
                )
            ).to.emit(feeDistribution, "FeeCollected")
                .withArgs(await user.getAddress(), await mockOmniCoin.getAddress(), feeAmount, "Trading fee");
            
            expect(await mockOmniCoin.balanceOf(await feeDistribution.getAddress()))
                .to.equal(feeAmount);
        });
        
        it("Should track fees by source", async function () {
            const feeAmount1 = ethers.parseUnits("50", 6);
            const feeAmount2 = ethers.parseUnits("30", 6);
            
            await mockOmniCoin.mint(await user.getAddress(), feeAmount1 + feeAmount2);
            await mockOmniCoin.connect(user).approve(await feeDistribution.getAddress(), feeAmount1 + feeAmount2);
            
            await feeDistribution.connect(user).collectFee(
                await mockOmniCoin.getAddress(),
                feeAmount1,
                "Bridge fee"
            );
            
            await feeDistribution.connect(user).collectFee(
                await mockOmniCoin.getAddress(),
                feeAmount2,
                "Privacy fee"
            );
            
            expect(await feeDistribution.totalCollected(await mockOmniCoin.getAddress()))
                .to.equal(feeAmount1 + feeAmount2);
        });
    });
    
    describe("Emergency Functions", function () {
        beforeEach(async function () {
            await mockOmniCoin.mint(await feeDistribution.getAddress(), ethers.parseUnits("1000", 6));
        });
        
        it("Should pause fee distribution", async function () {
            await feeDistribution.connect(owner).pause();
            
            await expect(
                feeDistribution.connect(owner).distributeFees(await mockOmniCoin.getAddress())
            ).to.be.revertedWithCustomError(feeDistribution, "EnforcedPause");
        });
        
        it("Should allow emergency withdrawal", async function () {
            const balance = await mockOmniCoin.balanceOf(await feeDistribution.getAddress());
            
            await feeDistribution.connect(owner).emergencyWithdraw(
                await mockOmniCoin.getAddress(),
                balance
            );
            
            expect(await mockOmniCoin.balanceOf(await owner.getAddress())).to.equal(balance);
            expect(await mockOmniCoin.balanceOf(await feeDistribution.getAddress())).to.equal(0);
        });
    });
});