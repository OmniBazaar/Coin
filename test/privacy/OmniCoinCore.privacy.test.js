const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinCore Privacy Functions", function () {
  // Test fixture for deployment
  async function deployOmniCoinFixture() {
    const [owner, user1, user2, treasury, development] = await ethers.getSigners();

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
      3 // minimum validators
    );
    await omniCoin.waitForDeployment();

    // Register OmniCoinCore
    await registry.registerContract(
      await registry.OMNICOIN_CORE(),
      await omniCoin.getAddress(),
      "OmniCoin Core"
    );

    // Setup roles
    await omniCoin.addValidator(await owner.getAddress());
    
    // Mint initial supply (simulate COTI environment)
    await omniCoin.mintInitialSupply();

    return { omniCoin, privacyFeeManager, registry, owner, user1, user2, treasury, development };
  }

  describe("Privacy Preference Settings", function () {
    it("Should allow users to set privacy preference", async function () {
      const { omniCoin, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Initially privacy should be false
      expect(await omniCoin.getPrivacyPreference(user1.address)).to.equal(false);
      
      // Set privacy preference to true
      await omniCoin.connect(user1).setPrivacyPreference(true);
      expect(await omniCoin.getPrivacyPreference(user1.address)).to.equal(true);
      
      // Set back to false
      await omniCoin.connect(user1).setPrivacyPreference(false);
      expect(await omniCoin.getPrivacyPreference(user1.address)).to.equal(false);
    });

    it("Should emit event when privacy preference changes", async function () {
      const { omniCoin, user1 } = await loadFixture(deployOmniCoinFixture);
      
      await expect(omniCoin.connect(user1).setPrivacyPreference(true))
        .to.emit(omniCoin, "PrivacyPreferenceChanged")
        .withArgs(user1.address, true);
    });
  });

  describe("Public Transfer Functions (No Privacy)", function () {
    it("Should perform public transfer without privacy fees", async function () {
      const { omniCoin, owner, user1, privacyFeeManager } = await loadFixture(deployOmniCoinFixture);
      
      const amount = ethers.parseUnits("100", 6); // 100 OMNI with 6 decimals
      
      // Get initial fee balance
      const initialFeeBalance = await privacyFeeManager.totalFeesCollected();
      
      // Perform public transfer
      await omniCoin.connect(owner).transferPublic(user1.address, amount);
      
      // Check that no privacy fees were collected
      const finalFeeBalance = await privacyFeeManager.totalFeesCollected();
      expect(finalFeeBalance).to.equal(initialFeeBalance);
    });

    it("Should perform public transferFrom without privacy fees", async function () {
      const { omniCoin, owner, user1, user2, privacyFeeManager } = await loadFixture(deployOmniCoinFixture);
      
      const amount = ethers.parseUnits("50", 6);
      
      // First approve user1 to spend owner's tokens
      // Note: In test environment without MPC, we simulate approval
      
      // Get initial fee balance
      const initialFeeBalance = await privacyFeeManager.totalFeesCollected();
      
      // Perform public transferFrom
      await omniCoin.connect(user1).transferFromPublic(owner.address, user2.address, amount);
      
      // Check that no privacy fees were collected
      const finalFeeBalance = await privacyFeeManager.totalFeesCollected();
      expect(finalFeeBalance).to.equal(initialFeeBalance);
    });
  });

  describe("Private Transfer Functions (With Privacy)", function () {
    beforeEach(async function () {
      // Note: These tests will fail in Hardhat environment without MPC
      // They are designed to pass when deployed on COTI testnet
    });

    it("Should require privacy preference enabled for private transfers", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const amount = ethers.parseUnits("100", 6);
      
      // Try private transfer without enabling privacy preference
      await expect(
        omniCoin.connect(owner).transferWithPrivacy(user1.address, amount, true)
      ).to.be.revertedWith("OmniCoinCore: Enable privacy preference first");
    });

    it("Should collect privacy fees for private transfers when MPC available", async function () {
      const { omniCoin, owner, user1, privacyFeeManager } = await loadFixture(deployOmniCoinFixture);
      
      // This test would work on COTI but not in Hardhat
      // Skipping for now as MPC is not available
      this.skip();
      
      // Enable MPC (admin only - would be done on COTI deployment)
      await omniCoin.setMpcAvailability(true);
      
      // Enable privacy preference
      await omniCoin.connect(owner).setPrivacyPreference(true);
      
      const amount = ethers.parseUnits("100", 6);
      const baseFee = ethers.parseUnits("0.1", 6); // 0.1 OMNI base fee
      const expectedPrivacyFee = baseFee * 10n; // 10x multiplier
      
      // Get initial fee balance
      const initialFeeBalance = await privacyFeeManager.totalFeesCollected();
      
      // Perform private transfer
      await omniCoin.connect(owner).transferWithPrivacy(user1.address, amount, true);
      
      // Check that privacy fees were collected
      const finalFeeBalance = await privacyFeeManager.totalFeesCollected();
      expect(finalFeeBalance - initialFeeBalance).to.equal(expectedPrivacyFee);
    });
  });

  describe("Validator Operations", function () {
    it("Should allow validators to be added and removed", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Add validator
      await omniCoin.addValidator(user1.address);
      expect(await omniCoin.isValidator(user1.address)).to.equal(true);
      expect(await omniCoin.validatorCount()).to.equal(2); // owner + user1
      
      // Remove validator
      await omniCoin.removeValidator(user1.address);
      expect(await omniCoin.isValidator(user1.address)).to.equal(false);
      expect(await omniCoin.validatorCount()).to.equal(1);
    });

    it("Should not allow removing validators below minimum", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);
      
      // Try to remove the only validator (should fail)
      await expect(
        omniCoin.removeValidator(owner.address)
      ).to.be.revertedWith("OmniCoinCore: Cannot go below minimum validators");
    });
  });

  describe("MPC Availability Management", function () {
    it("Should allow admin to set MPC availability", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Initially MPC should be false (Hardhat environment)
      expect(await omniCoin.isMpcAvailable()).to.equal(false);
      
      // Admin can set MPC availability
      await omniCoin.setMpcAvailability(true);
      expect(await omniCoin.isMpcAvailable()).to.equal(true);
      
      // Non-admin cannot set MPC availability
      await expect(
        omniCoin.connect(user1).setMpcAvailability(false)
      ).to.be.reverted;
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should handle zero amount transfers", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Public transfer with zero amount should succeed
      await expect(
        omniCoin.connect(owner).transferPublic(user1.address, 0)
      ).to.not.be.reverted;
    });

    it("Should respect pause functionality", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Pause the contract
      await omniCoin.pause();
      
      // Transfers should fail when paused
      await expect(
        omniCoin.connect(owner).transferPublic(user1.address, 100)
      ).to.be.revertedWith("OmniCoinCore: Contract is paused");
      
      // Unpause
      await omniCoin.unpause();
      
      // Transfers should work again
      await expect(
        omniCoin.connect(owner).transferPublic(user1.address, 100)
      ).to.not.be.reverted;
    });
  });
});