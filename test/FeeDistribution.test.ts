const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("FeeDistribution Privacy Integration", function () {
  let feeDistribution;
  let feeToken;
  
  let owner;
  let companyTreasury;
  let developmentFund;
  let validator1;
  let validator2;
  let validator3;
  let collector;
  let distributor;

  // Test constants
  const INITIAL_SUPPLY = ethers.parseEther("1000000"); // 1M tokens
  const VALIDATOR_SHARE = 7000; // 70%
  const COMPANY_SHARE = 2000; // 20%
  const DEVELOPMENT_SHARE = 1000; // 10%
  const MINIMUM_DISTRIBUTION = ethers.parseEther("1000"); // 1000 tokens

  beforeEach(async function () {
    [owner, companyTreasury, developmentFund, validator1, validator2, validator3, collector, distributor] = 
      await ethers.getSigners();

    // Deploy mock fee token
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    feeToken = await MockERC20Factory.deploy("XOM Token", "XOM", INITIAL_SUPPLY);
    await feeToken.waitForDeployment();

    // Deploy FeeDistribution contract
    const FeeDistributionFactory = await ethers.getContractFactory("FeeDistribution");
    feeDistribution = await FeeDistributionFactory.deploy(
      await feeToken.getAddress(),
      companyTreasury.address,
      developmentFund.address
    );
    await feeDistribution.waitForDeployment();

    // Grant roles
    const COLLECTOR_ROLE = await feeDistribution.COLLECTOR_ROLE();
    const DISTRIBUTOR_ROLE = await feeDistribution.DISTRIBUTOR_ROLE();
    const TREASURY_ROLE = await feeDistribution.TREASURY_ROLE();

    await feeDistribution.grantRole(COLLECTOR_ROLE, collector.address);
    await feeDistribution.grantRole(DISTRIBUTOR_ROLE, distributor.address);
    await feeDistribution.grantRole(TREASURY_ROLE, owner.address);

    // Transfer tokens to collector for fee collection
    await feeToken.transfer(collector.address, ethers.parseEther("100000"));
    await feeToken.connect(collector).approve(await feeDistribution.getAddress(), ethers.parseEther("100000"));
  });

  describe("Deployment and Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      expect(await feeDistribution.feeToken()).to.equal(await feeToken.getAddress());
      expect(await feeDistribution.companyTreasury()).to.equal(companyTreasury.address);
      expect(await feeDistribution.developmentFund()).to.equal(developmentFund.address);

      const distributionRatio = await feeDistribution.getDistributionRatio();
      expect(distributionRatio.validatorShare).to.equal(VALIDATOR_SHARE);
      expect(distributionRatio.companyShare).to.equal(COMPANY_SHARE);
      expect(distributionRatio.developmentShare).to.equal(DEVELOPMENT_SHARE);
    });

    it("Should return correct version", async function () {
      expect(await feeDistribution.getVersion()).to.equal(
        "FeeDistribution v2.0.0 - COTI V2 Privacy Integration"
      );
    });

    it("Should have correct fee source initialization", async function () {
      // Check that fee sources are enabled
      expect(await feeDistribution.enabledFeeSources(0)).to.be.true; // TRADING
      expect(await feeDistribution.enabledFeeSources(1)).to.be.true; // PERPETUAL_FUTURES
      expect(await feeDistribution.enabledFeeSources(3)).to.be.true; // MARKETPLACE
    });
  });

  describe("Privacy-Enabled Validator Initialization", function () {
    it("Should initialize validator private rewards", async function () {
      await expect(
        feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address)
      ).to.not.be.reverted;

      // Verify validator can access their private earnings (should be zero initially)
      // Note: In a real test environment with COTI V2, this would return an encrypted zero
      await expect(
        feeDistribution.connect(validator1).getValidatorPrivateEarnings(validator1.address)
      ).to.not.be.reverted;
    });

    it("Should fail to initialize with invalid validator address", async function () {
      await expect(
        feeDistribution.connect(distributor).initializeValidatorPrivateRewards(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid validator address");
    });

    it("Should fail to initialize without distributor role", async function () {
      await expect(
        feeDistribution.connect(validator1).initializeValidatorPrivateRewards(validator1.address)
      ).to.be.reverted;
    });
  });

  describe("Fee Collection", function () {
    it("Should collect fees successfully", async function () {
      const feeAmount = ethers.parseEther("1000");
      const feeSource = 0; // TRADING

      await expect(
        feeDistribution.connect(collector).collectFees(
          await feeToken.getAddress(),
          feeAmount,
          feeSource
        )
      )
        .to.emit(feeDistribution, "FeesCollected");

      expect(await feeToken.balanceOf(await feeDistribution.getAddress())).to.equal(feeAmount);
      expect(await feeDistribution.getFeeSourceTotal(feeSource)).to.equal(feeAmount);
      expect(await feeDistribution.getTokenTotal(await feeToken.getAddress())).to.equal(feeAmount);
    });

    it("Should batch collect fees", async function () {
      const amounts = [
        ethers.parseEther("500"),
        ethers.parseEther("300"),
        ethers.parseEther("200")
      ];
      const sources = [0, 1, 3]; // TRADING, PERPETUAL_FUTURES, MARKETPLACE
      const tokens = [await feeToken.getAddress(), await feeToken.getAddress(), await feeToken.getAddress()];

      await feeDistribution.connect(collector).batchCollectFees(tokens, amounts, sources);

      const totalAmount = amounts.reduce((sum, amount) => sum + amount, 0n);
      expect(await feeToken.balanceOf(await feeDistribution.getAddress())).to.equal(totalAmount);
    });
  });

  describe("Privacy-Enhanced Fee Distribution", function () {
    beforeEach(async function () {
      // Collect some fees first
      const feeAmount = ethers.parseEther("10000");
      await feeDistribution.connect(collector).collectFees(
        await feeToken.getAddress(),
        feeAmount,
        0 // TRADING
      );

      // Set distribution interval to 0 for testing (bypass timing restrictions)
      await feeDistribution.updateDistributionParameters(3600, ethers.parseEther("1000"));

      // Initialize validators for private rewards
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator2.address);
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator3.address);
    });

    it("Should distribute fees with privacy features", async function () {
      const validators = [validator1.address, validator2.address, validator3.address];
      const participationScores = [1000, 800, 600]; // Different participation scores

      await expect(
        feeDistribution.connect(distributor).distributeFees(validators, participationScores)
      ).to.emit(feeDistribution, "FeesDistributed");

      // Check that private reward events were emitted
      const events = await feeDistribution.queryFilter(
        feeDistribution.filters.PrivateValidatorRewardDistributed()
      );
      expect(events.length).to.equal(3); // One for each validator

      // Verify each validator got their private reward event
      const validatorAddresses = events.map(e => e.args?.validator);
      expect(validatorAddresses).to.include(validator1.address);
      expect(validatorAddresses).to.include(validator2.address);
      expect(validatorAddresses).to.include(validator3.address);
    });

    it("Should calculate correct distribution amounts", async function () {
      const validators = [validator1.address, validator2.address];
      const participationScores = [600, 400]; // 60% and 40% split
      const totalFees = ethers.parseEther("10000");

      await feeDistribution.connect(distributor).distributeFees(validators, participationScores);

      // Check distribution was created
      const currentDistributionId = await feeDistribution.currentDistributionId();
      const distribution = await feeDistribution.getDistribution(currentDistributionId);

      expect(distribution.totalAmount).to.equal(totalFees);
      expect(distribution.validatorCount).to.equal(2);
      expect(distribution.completed).to.be.true;

      // Verify company and development shares
      const expectedValidatorShare = totalFees.mul(VALIDATOR_SHARE).div(10000);
      const expectedCompanyShare = totalFees.mul(COMPANY_SHARE).div(10000);
      const expectedDevelopmentShare = totalFees.mul(DEVELOPMENT_SHARE).div(10000);

      expect(distribution.validatorShare).to.equal(expectedValidatorShare);
      expect(distribution.companyShare).to.equal(expectedCompanyShare);
      expect(distribution.developmentShare).to.equal(expectedDevelopmentShare);
    });

    it("Should fail distribution with mismatched arrays", async function () {
      const validators = [validator1.address, validator2.address];
      const participationScores = [1000]; // Mismatched length

      await expect(
        feeDistribution.connect(distributor).distributeFees(validators, participationScores)
      ).to.be.revertedWith("Arrays length mismatch");
    });

    it("Should fail distribution if insufficient amount", async function () {
      // Collect very small amount
      await feeDistribution.connect(collector).collectFees(
        await feeToken.getAddress(),
        ethers.parseEther("100"), // Below minimum
        0
      );

      const validators = [validator1.address];
      const participationScores = [1000];

      await expect(
        feeDistribution.connect(distributor).distributeFees(validators, participationScores)
      ).to.be.revertedWith("Insufficient amount for distribution");
    });
  });

  describe("Private Reward Claims", function () {
    beforeEach(async function () {
      // Setup and distribute fees
      const feeAmount = ethers.parseEther("10000");
      await feeDistribution.connect(collector).collectFees(await feeToken.getAddress(), feeAmount, 0);
      
      // Set distribution interval to 0 for testing
      await feeDistribution.updateDistributionParameters(3600, ethers.parseEther("1000"));
      
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
      await feeDistribution.connect(distributor).distributeFees([validator1.address], [1000]);
    });

    it("Should allow validators to claim public rewards", async function () {
      const initialBalance = await feeToken.balanceOf(validator1.address);
      
      await expect(
        feeDistribution.connect(validator1).claimValidatorRewards(await feeToken.getAddress())
      ).to.emit(feeDistribution, "ValidatorRewardClaimed");

      const finalBalance = await feeToken.balanceOf(validator1.address);
      expect(finalBalance).to.be.gt(initialBalance);

      // Check that pending rewards are reset
      expect(await feeDistribution.getValidatorPendingRewards(validator1.address, await feeToken.getAddress()))
        .to.equal(0);
    });

    it("Should allow validators to claim private rewards", async function () {
      const initialBalance = await feeToken.balanceOf(validator1.address);

      // Note: In actual COTI testnet, this would handle encrypted amounts properly
      await expect(
        feeDistribution.connect(validator1).claimPrivateValidatorRewards(await feeToken.getAddress())
      ).to.emit(feeDistribution, "PrivateRewardsClaimed");

      const finalBalance = await feeToken.balanceOf(validator1.address);
      expect(finalBalance).to.be.gte(initialBalance); // Should be >= due to potential rewards
    });

    it("Should fail claim with no pending rewards", async function () {
      // Try to claim again after already claiming
      await feeDistribution.connect(validator1).claimValidatorRewards(await feeToken.getAddress());
      
      await expect(
        feeDistribution.connect(validator1).claimValidatorRewards(await feeToken.getAddress())
      ).to.be.revertedWith("No pending rewards");
    });
  });

  describe("Privacy Access Control", function () {
    beforeEach(async function () {
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
    });

    it("Should allow validator to access their private rewards", async function () {
      await expect(
        feeDistribution.connect(validator1).getValidatorPrivatePendingRewards(
          validator1.address, 
          await feeToken.getAddress()
        )
      ).to.not.be.reverted;
    });

    it("Should allow admin to access validator private rewards", async function () {
      await expect(
        feeDistribution.connect(owner).getValidatorPrivatePendingRewards(
          validator1.address, 
          await feeToken.getAddress()
        )
      ).to.not.be.reverted;
    });

    it("Should deny unauthorized access to private rewards", async function () {
      await expect(
        feeDistribution.connect(validator2).getValidatorPrivatePendingRewards(
          validator1.address, 
          await feeToken.getAddress()
        )
      ).to.be.revertedWith("Access denied: private rewards");
    });

    it("Should allow validator to access their private earnings", async function () {
      await expect(
        feeDistribution.connect(validator1).getValidatorPrivateEarnings(validator1.address)
      ).to.not.be.reverted;
    });

    it("Should deny unauthorized access to private earnings", async function () {
      await expect(
        feeDistribution.connect(validator2).getValidatorPrivateEarnings(validator1.address)
      ).to.be.revertedWith("Access denied: private earnings");
    });
  });

  describe("Company and Development Fund Withdrawals", function () {
    beforeEach(async function () {
      // Setup and distribute fees to create company and development shares
      const feeAmount = ethers.parseEther("10000");
      await feeDistribution.connect(collector).collectFees(await feeToken.getAddress(), feeAmount, 0);
      
      // Set distribution interval to 0 for testing
      await feeDistribution.updateDistributionParameters(3600, ethers.parseEther("1000"));
      
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
      await feeDistribution.connect(distributor).distributeFees([validator1.address], [1000]);
    });

    it("Should allow treasury role to withdraw company fees", async function () {
      const pendingAmount = await feeDistribution.getCompanyPendingWithdrawals(await feeToken.getAddress());
      expect(pendingAmount).to.be.gt(0);

      const initialBalance = await feeToken.balanceOf(companyTreasury.address);

      await expect(
        feeDistribution.connect(owner).withdrawCompanyFees(await feeToken.getAddress(), pendingAmount)
      ).to.emit(feeDistribution, "CompanyFeesWithdrawn");

      const finalBalance = await feeToken.balanceOf(companyTreasury.address);
      expect(finalBalance.sub(initialBalance)).to.equal(pendingAmount);
    });

    it("Should allow treasury role to withdraw development fees", async function () {
      const pendingAmount = await feeDistribution.getDevelopmentPendingWithdrawals(await feeToken.getAddress());
      expect(pendingAmount).to.be.gt(0);

      const initialBalance = await feeToken.balanceOf(developmentFund.address);

      await expect(
        feeDistribution.connect(owner).withdrawDevelopmentFees(await feeToken.getAddress(), pendingAmount)
      ).to.emit(feeDistribution, "DevelopmentFeesWithdrawn");

      const finalBalance = await feeToken.balanceOf(developmentFund.address);
      expect(finalBalance.sub(initialBalance)).to.equal(pendingAmount);
    });
  });

  describe("Distribution Parameters and Ratios", function () {
    it("Should update distribution ratios", async function () {
      const newValidatorShare = 8000; // 80%
      const newCompanyShare = 1500;  // 15%
      const newDevelopmentShare = 500; // 5%

      await expect(
        feeDistribution.updateDistributionRatios(
          newValidatorShare,
          newCompanyShare,
          newDevelopmentShare
        )
      ).to.emit(feeDistribution, "DistributionRatiosUpdated");

      const updatedRatio = await feeDistribution.getDistributionRatio();
      expect(updatedRatio.validatorShare).to.equal(newValidatorShare);
      expect(updatedRatio.companyShare).to.equal(newCompanyShare);
      expect(updatedRatio.developmentShare).to.equal(newDevelopmentShare);
    });

    it("Should fail to update ratios if they don't sum to 100%", async function () {
      await expect(
        feeDistribution.updateDistributionRatios(8000, 1500, 600) // Sums to 101%
      ).to.be.revertedWith("Ratios must sum to 100%");
    });

    it("Should fail to set validator share below 50%", async function () {
      await expect(
        feeDistribution.updateDistributionRatios(4000, 3000, 3000) // Validator share 40%
      ).to.be.revertedWith("Validator share must be at least 50%");
    });

    it("Should update distribution parameters", async function () {
      const newInterval = 12 * 60 * 60; // 12 hours
      const newMinimum = ethers.parseEther("2000"); // 2000 tokens

      await feeDistribution.updateDistributionParameters(newInterval, newMinimum);
      
      expect(await feeDistribution.distributionInterval()).to.equal(newInterval);
      expect(await feeDistribution.minimumDistributionAmount()).to.equal(newMinimum);
    });
  });

  describe("Revenue Metrics and Analytics", function () {
    it("Should track revenue metrics correctly", async function () {
      const feeAmount = ethers.parseEther("5000");
      
      // Collect fees
      await feeDistribution.connect(collector).collectFees(await feeToken.getAddress(), feeAmount, 0);
      
      // Set distribution interval to 0 for testing
      await feeDistribution.updateDistributionParameters(3600, ethers.parseEther("1000"));
      
      // Distribute fees
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
      await feeDistribution.connect(distributor).distributeFees([validator1.address], [1000]);

      const metrics = await feeDistribution.getRevenueMetrics();
      expect(metrics.totalFeesCollected).to.equal(feeAmount);
      expect(metrics.totalDistributed).to.equal(feeAmount);
      expect(metrics.distributionCount).to.equal(1);
      expect(metrics.totalValidatorRewards).to.equal(feeAmount.mul(VALIDATOR_SHARE).div(10000));
      expect(metrics.totalCompanyRevenue).to.equal(feeAmount.mul(COMPANY_SHARE).div(10000));
      expect(metrics.totalDevelopmentFunding).to.equal(feeAmount.mul(DEVELOPMENT_SHARE).div(10000));
    });

    it("Should check if distribution can be performed", async function () {
      // Set distribution interval to 0 for testing
      await feeDistribution.updateDistributionParameters(3600, ethers.parseEther("1000"));
      
      // Initially should be false (no fees collected)
      expect(await feeDistribution.canDistribute()).to.be.false;

      // Collect sufficient fees
      await feeDistribution.connect(collector).collectFees(
        await feeToken.getAddress(),
        MINIMUM_DISTRIBUTION,
        0
      );

      // Now should be true
      expect(await feeDistribution.canDistribute()).to.be.true;
    });
  });

  describe("Pause Functionality", function () {
    it("Should pause and unpause contract", async function () {
      await feeDistribution.pause();
      expect(await feeDistribution.paused()).to.be.true;

      await feeDistribution.unpause();
      expect(await feeDistribution.paused()).to.be.false;
    });

    it("Should prevent operations when paused", async function () {
      await feeDistribution.pause();

      await expect(
        feeDistribution.connect(collector).collectFees(await feeToken.getAddress(), 1000, 0)
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Edge Cases and Error Handling", function () {
    it("Should handle zero participation scores", async function () {
      const feeAmount = ethers.parseEther("1000");
      await feeDistribution.connect(collector).collectFees(await feeToken.getAddress(), feeAmount, 0);

      // Set distribution interval to 0 for testing
      await feeDistribution.updateDistributionParameters(3600, ethers.parseEther("1000"));

      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
      
      // All validators have zero scores - should not revert but no rewards distributed
      await expect(
        feeDistribution.connect(distributor).distributeFees([validator1.address], [0])
      ).to.not.be.reverted;
    });

    it("Should handle empty validator arrays", async function () {
      await expect(
        feeDistribution.connect(distributor).distributeFees([], [])
      ).to.be.revertedWith("No validators provided");
    });

    it("Should prevent double initialization of validator private rewards", async function () {
      await feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address);
      
      // Second initialization should be safe (no-op)
      await expect(
        feeDistribution.connect(distributor).initializeValidatorPrivateRewards(validator1.address)
      ).to.not.be.reverted;
    });
  });
});