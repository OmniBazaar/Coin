const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinStaking Privacy Functions", function () {
  // Test fixture for deployment
  async function deployStakingFixture() {
    const [owner, staker1, staker2, treasury, development] = await ethers.getSigners();

    // Deploy Registry
    const Registry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await Registry.deploy();
    await registry.waitForDeployment();

    // Deploy PrivacyFeeManager
    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await registry.getAddress(),
      await treasury.getAddress(),
      await development.getAddress()
    );
    await privacyFeeManager.waitForDeployment();

    // Register PrivacyFeeManager
    await registry.registerContract(
      await registry.FEE_MANAGER(),
      await privacyFeeManager.getAddress(),
      "Privacy Fee Manager"
    );

    // Deploy OmniCoinCore
    const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
    const omniCoin = await OmniCoinCore.deploy(
      await registry.getAddress(),
      await owner.getAddress(),
      1
    );
    await omniCoin.waitForDeployment();

    // Register OmniCoinCore
    await registry.registerContract(
      await registry.OMNICOIN_CORE(),
      await omniCoin.getAddress(),
      "OmniCoin Core"
    );

    // Deploy OmniCoinStaking
    const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
    const staking = await OmniCoinStaking.deploy(
      await omniCoin.getAddress(),
      100, // 1% reward rate (basis points)
      86400, // 1 day lock period
      await privacyFeeManager.getAddress()
    );
    await staking.waitForDeployment();

    // Setup
    await omniCoin.mintInitialSupply();
    await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), await staking.getAddress());

    return { 
      staking, omniCoin, privacyFeeManager, registry,
      owner, staker1, staker2, treasury, development 
    };
  }

  describe("Public Staking (No Privacy)", function () {
    it("Should stake tokens without privacy fees", async function () {
      const { staking, staker1, privacyFeeManager } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("1000", 6); // 1000 OMNI
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Stake tokens publicly
      await staking.connect(staker1).stake(stakeAmount);
      
      // Verify no privacy fees collected
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees).to.equal(initialFees);
      
      // Verify stake recorded
      const stakeInfo = await staking.stakes(staker1.address);
      expect(stakeInfo.amount).to.equal(stakeAmount);
      expect(stakeInfo.isPrivate).to.equal(false);
    });

    it("Should calculate and claim rewards publicly", async function () {
      const { staking, staker1 } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("1000", 6);
      
      // Stake tokens
      await staking.connect(staker1).stake(stakeAmount);
      
      // Fast forward time to accumulate rewards
      await time.increase(86400 * 30); // 30 days
      
      // Check rewards
      const rewards = await staking.calculateRewards(staker1.address);
      expect(rewards).to.be.gt(0);
      
      // Claim rewards
      await staking.connect(staker1).claimRewards();
      
      // Verify rewards claimed
      const stakeInfo = await staking.stakes(staker1.address);
      expect(stakeInfo.lastRewardTime).to.be.gt(0);
    });
  });

  describe("Private Staking (With Privacy)", function () {
    it("Should require privacy preference for private staking", async function () {
      const { staking, staker1 } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("2000", 6);
      
      // Try to stake privately without privacy preference
      await expect(
        staking.connect(staker1).stakeWithPrivacy(stakeAmount, true)
      ).to.be.revertedWith("Enable privacy preference first");
    });

    it("Should collect privacy fees for private staking when MPC available", async function () {
      const { staking, omniCoin, staker1, privacyFeeManager } = await loadFixture(deployStakingFixture);
      
      // This test would work on COTI but not in Hardhat
      this.skip();
      
      // Setup for privacy
      await omniCoin.setMpcAvailability(true);
      await omniCoin.connect(staker1).setPrivacyPreference(true);
      await staking.setMpcAvailability(true);
      
      const stakeAmount = ethers.parseUnits("5000", 6);
      const baseFee = ethers.parseUnits("5", 6); // 5 OMNI base fee
      const expectedPrivacyFee = baseFee * 10n; // 10x for privacy
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Stake privately
      await staking.connect(staker1).stakeWithPrivacy(stakeAmount, true);
      
      // Verify privacy fees collected
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees - initialFees).to.equal(expectedPrivacyFee);
    });
  });

  describe("Unstaking Operations", function () {
    it("Should enforce lock period for unstaking", async function () {
      const { staking, staker1 } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("500", 6);
      
      // Stake tokens
      await staking.connect(staker1).stake(stakeAmount);
      
      // Try to unstake immediately (should fail)
      await expect(
        staking.connect(staker1).unstake(stakeAmount)
      ).to.be.revertedWith("Tokens still locked");
      
      // Fast forward past lock period
      await time.increase(86401); // 1 day + 1 second
      
      // Now unstaking should work
      await staking.connect(staker1).unstake(stakeAmount);
      
      // Verify unstaked
      const stakeInfo = await staking.stakes(staker1.address);
      expect(stakeInfo.amount).to.equal(0);
    });

    it("Should handle partial unstaking", async function () {
      const { staking, staker1 } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("1000", 6);
      const unstakeAmount = ethers.parseUnits("300", 6);
      
      // Stake tokens
      await staking.connect(staker1).stake(stakeAmount);
      
      // Fast forward past lock period
      await time.increase(86401);
      
      // Unstake partially
      await staking.connect(staker1).unstake(unstakeAmount);
      
      // Verify remaining stake
      const stakeInfo = await staking.stakes(staker1.address);
      expect(stakeInfo.amount).to.equal(stakeAmount - unstakeAmount);
    });
  });

  describe("Reward Distribution", function () {
    it("Should distribute rewards proportionally to stake amounts", async function () {
      const { staking, staker1, staker2 } = await loadFixture(deployStakingFixture);
      
      const stake1Amount = ethers.parseUnits("1000", 6);
      const stake2Amount = ethers.parseUnits("2000", 6);
      
      // Both users stake
      await staking.connect(staker1).stake(stake1Amount);
      await staking.connect(staker2).stake(stake2Amount);
      
      // Fast forward to accumulate rewards
      await time.increase(86400 * 10); // 10 days
      
      // Calculate rewards
      const rewards1 = await staking.calculateRewards(staker1.address);
      const rewards2 = await staking.calculateRewards(staker2.address);
      
      // Staker2 should have approximately 2x rewards
      const ratio = rewards2 * 1000n / rewards1; // Multiply by 1000 for precision
      expect(ratio).to.be.closeTo(2000n, 100n); // Allow 10% variance
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should prevent staking zero amount", async function () {
      const { staking, staker1 } = await loadFixture(deployStakingFixture);
      
      await expect(
        staking.connect(staker1).stake(0)
      ).to.be.revertedWith("Amount must be greater than 0");
    });

    it("Should prevent unstaking more than staked", async function () {
      const { staking, staker1 } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("100", 6);
      
      // Stake tokens
      await staking.connect(staker1).stake(stakeAmount);
      
      // Fast forward past lock period
      await time.increase(86401);
      
      // Try to unstake more than staked
      await expect(
        staking.connect(staker1).unstake(stakeAmount + 1n)
      ).to.be.revertedWith("Insufficient staked balance");
    });

    it("Should handle pause functionality", async function () {
      const { staking, staker1, owner } = await loadFixture(deployStakingFixture);
      
      const stakeAmount = ethers.parseUnits("100", 6);
      
      // Pause contract
      await staking.connect(owner).pause();
      
      // Try to stake while paused
      await expect(
        staking.connect(staker1).stake(stakeAmount)
      ).to.be.reverted;
      
      // Unpause
      await staking.connect(owner).unpause();
      
      // Should work now
      await expect(
        staking.connect(staker1).stake(stakeAmount)
      ).to.not.be.reverted;
    });

    it("Should update reward rate correctly", async function () {
      const { staking, owner } = await loadFixture(deployStakingFixture);
      
      // Get initial reward rate
      const initialRate = await staking.rewardRate();
      expect(initialRate).to.equal(100); // 1%
      
      // Update reward rate
      const newRate = 200; // 2%
      await staking.connect(owner).updateRewardRate(newRate);
      
      // Verify update
      const updatedRate = await staking.rewardRate();
      expect(updatedRate).to.equal(newRate);
    });
  });
});