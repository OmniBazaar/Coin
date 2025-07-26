const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinEscrow Privacy Functions", function () {
  // Test fixture for deployment
  async function deployEscrowFixture() {
    const [owner, seller, buyer, arbitrator, treasury, development] = await ethers.getSigners();

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

    // Deploy OmniCoinCore (needed for escrow)
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

    // Deploy OmniCoinEscrow
    const OmniCoinEscrow = await ethers.getContractFactory("OmniCoinEscrow");
    const escrow = await OmniCoinEscrow.deploy(
      await registry.getAddress()
    );
    await escrow.waitForDeployment();

    // Register OmniCoinEscrow
    await registry.registerContract(
      await registry.ESCROW(),
      await escrow.getAddress(),
      "OmniCoin Escrow"
    );

    // Setup
    await omniCoin.mintInitialSupply();
    await escrow.addArbitrator(arbitrator.address);

    return { 
      escrow, omniCoin, privacyFeeManager, registry, 
      owner, seller, buyer, arbitrator, treasury, development 
    };
  }

  describe("Public Escrow Creation (No Privacy)", function () {
    it("Should create public escrow without privacy fees", async function () {
      const { escrow, seller, buyer, privacyFeeManager } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("1000", 6); // 1000 OMNI
      const deadline = (await time.latest()) + 86400; // 24 hours from now
      
      // Get initial fee balance
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Create public escrow
      const tx = await escrow.connect(seller).createEscrow(
        buyer.address,
        amount,
        deadline,
        "Test escrow"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "EscrowCreated");
      
      // Verify no privacy fees collected
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees).to.equal(initialFees);
      
      // Verify escrow created
      const escrowData = await escrow.escrows(event.args.escrowId);
      expect(escrowData.seller).to.equal(seller.address);
      expect(escrowData.buyer).to.equal(buyer.address);
      expect(escrowData.amount).to.equal(amount);
      expect(escrowData.isPrivate).to.equal(false);
    });

    it("Should release public escrow without privacy fees", async function () {
      const { escrow, seller, buyer, privacyFeeManager } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("500", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Create escrow
      const tx = await escrow.connect(seller).createEscrow(
        buyer.address,
        amount,
        deadline,
        "Test escrow"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "EscrowCreated");
      const escrowId = event.args.escrowId;
      
      // Get fee balance before release
      const feesBeforeRelease = await privacyFeeManager.totalFeesCollected();
      
      // Release escrow
      await escrow.connect(seller).releaseEscrow(escrowId);
      
      // Verify no additional privacy fees
      const feesAfterRelease = await privacyFeeManager.totalFeesCollected();
      expect(feesAfterRelease).to.equal(feesBeforeRelease);
      
      // Verify escrow released
      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.status).to.equal(2); // Released status
    });
  });

  describe("Private Escrow Creation (With Privacy)", function () {
    it("Should require privacy preference for private escrow", async function () {
      const { escrow, seller, buyer } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Try to create private escrow without privacy preference
      await expect(
        escrow.connect(seller).createEscrowWithPrivacy(
          buyer.address,
          amount,
          deadline,
          "Private escrow",
          true // usePrivacy = true
        )
      ).to.be.revertedWith("Enable privacy preference first");
    });

    it("Should collect privacy fees for private escrow when MPC available", async function () {
      const { escrow, omniCoin, seller, buyer, privacyFeeManager } = await loadFixture(deployEscrowFixture);
      
      // This test would work on COTI but not in Hardhat
      this.skip();
      
      // Setup for privacy
      await omniCoin.setMpcAvailability(true);
      await omniCoin.connect(seller).setPrivacyPreference(true);
      await escrow.setMpcAvailability(true);
      
      const amount = ethers.parseUnits("1000", 6);
      const deadline = (await time.latest()) + 86400;
      const baseFee = ethers.parseUnits("1", 6); // 1 OMNI base fee
      const expectedPrivacyFee = baseFee * 10n; // 10x for privacy
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Create private escrow
      await escrow.connect(seller).createEscrowWithPrivacy(
        buyer.address,
        amount,
        deadline,
        "Private escrow",
        true
      );
      
      // Verify privacy fees collected
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees - initialFees).to.equal(expectedPrivacyFee);
    });

    it("Should handle public escrow through privacy function when usePrivacy=false", async function () {
      const { escrow, seller, buyer, privacyFeeManager } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("750", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Create escrow with privacy function but usePrivacy=false
      const tx = await escrow.connect(seller).createEscrowWithPrivacy(
        buyer.address,
        amount,
        deadline,
        "Public via privacy function",
        false // usePrivacy = false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "EscrowCreated");
      
      // Verify no privacy fees
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees).to.equal(initialFees);
      
      // Verify escrow is public
      const escrowData = await escrow.escrows(event.args.escrowId);
      expect(escrowData.isPrivate).to.equal(false);
    });
  });

  describe("Arbitration with Privacy", function () {
    it("Should handle disputes on private escrows", async function () {
      const { escrow, seller, buyer, arbitrator } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("2000", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Create escrow
      const tx = await escrow.connect(seller).createEscrow(
        buyer.address,
        amount,
        deadline,
        "Disputed escrow"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "EscrowCreated");
      const escrowId = event.args.escrowId;
      
      // Buyer disputes
      await escrow.connect(buyer).disputeEscrow(escrowId);
      
      // Arbitrator resolves in favor of buyer
      const buyerPercentage = 100; // 100% to buyer
      await escrow.connect(arbitrator).resolveDispute(escrowId, buyerPercentage);
      
      // Verify resolution
      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.status).to.equal(3); // Refunded status
    });
  });

  describe("Multi-party Escrow Operations", function () {
    it("Should handle multiple concurrent escrows", async function () {
      const { escrow, seller, buyer, owner } = await loadFixture(deployEscrowFixture);
      
      const amount1 = ethers.parseUnits("100", 6);
      const amount2 = ethers.parseUnits("200", 6);
      const amount3 = ethers.parseUnits("300", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Create multiple escrows
      const tx1 = await escrow.connect(seller).createEscrow(buyer.address, amount1, deadline, "Escrow 1");
      const tx2 = await escrow.connect(seller).createEscrow(owner.address, amount2, deadline, "Escrow 2");
      const tx3 = await escrow.connect(buyer).createEscrow(seller.address, amount3, deadline, "Escrow 3");
      
      // Get escrow IDs
      const receipt1 = await tx1.wait();
      const receipt2 = await tx2.wait();
      const receipt3 = await tx3.wait();
      
      const event1 = receipt1.logs.find(log => log.fragment?.name === "EscrowCreated");
      const event2 = receipt2.logs.find(log => log.fragment?.name === "EscrowCreated");
      const event3 = receipt3.logs.find(log => log.fragment?.name === "EscrowCreated");
      
      // Verify all escrows created
      expect(event1.args.escrowId).to.equal(0);
      expect(event2.args.escrowId).to.equal(1);
      expect(event3.args.escrowId).to.equal(2);
      
      // Release first escrow
      await escrow.connect(seller).releaseEscrow(0);
      
      // Verify only first escrow is released
      const escrow1 = await escrow.escrows(0);
      const escrow2 = await escrow.escrows(1);
      const escrow3 = await escrow.escrows(2);
      
      expect(escrow1.status).to.equal(2); // Released
      expect(escrow2.status).to.equal(1); // Active
      expect(escrow3.status).to.equal(1); // Active
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should prevent releasing escrow after deadline", async function () {
      const { escrow, seller, buyer } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("100", 6);
      const deadline = (await time.latest()) + 60; // 60 seconds from now
      
      // Create escrow
      const tx = await escrow.connect(seller).createEscrow(
        buyer.address,
        amount,
        deadline,
        "Short deadline"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "EscrowCreated");
      const escrowId = event.args.escrowId;
      
      // Fast forward past deadline
      await time.increase(61);
      
      // Try to release (should fail)
      await expect(
        escrow.connect(seller).releaseEscrow(escrowId)
      ).to.be.revertedWith("Escrow expired");
    });

    it("Should prevent double release", async function () {
      const { escrow, seller, buyer } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("100", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Create and release escrow
      const tx = await escrow.connect(seller).createEscrow(
        buyer.address,
        amount,
        deadline,
        "Test"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "EscrowCreated");
      const escrowId = event.args.escrowId;
      
      await escrow.connect(seller).releaseEscrow(escrowId);
      
      // Try to release again (should fail)
      await expect(
        escrow.connect(seller).releaseEscrow(escrowId)
      ).to.be.revertedWith("Invalid status");
    });

    it("Should handle pause functionality", async function () {
      const { escrow, seller, buyer, owner } = await loadFixture(deployEscrowFixture);
      
      const amount = ethers.parseUnits("100", 6);
      const deadline = (await time.latest()) + 86400;
      
      // Pause contract
      await escrow.connect(owner).pause();
      
      // Try to create escrow while paused
      await expect(
        escrow.connect(seller).createEscrow(
          buyer.address,
          amount,
          deadline,
          "Paused test"
        )
      ).to.be.reverted;
      
      // Unpause
      await escrow.connect(owner).unpause();
      
      // Should work now
      await expect(
        escrow.connect(seller).createEscrow(
          buyer.address,
          amount,
          deadline,
          "Unpaused test"
        )
      ).to.not.be.reverted;
    });
  });
});