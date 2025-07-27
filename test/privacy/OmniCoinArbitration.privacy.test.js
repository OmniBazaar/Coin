const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinArbitration Privacy Functions", function () {
  // Test fixture
  async function deployArbitrationFixture() {
    const [owner, user1, user2, arbitrator1, arbitrator2, arbitrator3] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("contracts/MockERC20.sol:MockERC20");
    const omniToken = await MockERC20.deploy("OmniCoin", "OMNI", 6);
    const cotiToken = await MockERC20.deploy("COTI", "COTI", 18);
    await omniToken.waitForDeployment();
    await cotiToken.waitForDeployment();

    // Deploy PrivacyFeeManager
    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await omniToken.getAddress(),
      await cotiToken.getAddress(),
      owner.address, // Mock DEX router
      owner.address
    );
    await privacyFeeManager.waitForDeployment();

    // Deploy mock contracts
    const MockOmniCoinAccount = await ethers.getContractFactory("MockOmniCoinAccount");
    const mockAccount = await MockOmniCoinAccount.deploy();
    await mockAccount.waitForDeployment();

    const MockOmniCoinEscrow = await ethers.getContractFactory("MockOmniCoinEscrow");
    const mockEscrow = await MockOmniCoinEscrow.deploy();
    await mockEscrow.waitForDeployment();

    // Deploy Registry
    const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await OmniCoinRegistry.deploy(owner.address);
    await registry.waitForDeployment();

    // Deploy OmniCoinConfig
    const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
    const config = await OmniCoinConfig.deploy();
    await config.waitForDeployment();

    // Deploy OmniCoinArbitration
    const OmniCoinArbitration = await ethers.getContractFactory("OmniCoinArbitration");
    const arbitration = await OmniCoinArbitration.deploy(
      await omniToken.getAddress(),
      await mockAccount.getAddress(),
      await mockEscrow.getAddress(),
      await config.getAddress(),
      await registry.getAddress(),
      await privacyFeeManager.getAddress()
    );
    await arbitration.waitForDeployment();

    // Grant necessary roles
    await privacyFeeManager.grantRole(await privacyFeeManager.FEE_MANAGER_ROLE(), await arbitration.getAddress());

    // Mint tokens
    const mintAmount = ethers.parseUnits("100000", 6);
    await omniToken.mint(user1.address, mintAmount);
    await omniToken.mint(user2.address, mintAmount);
    await omniToken.mint(arbitrator1.address, mintAmount);
    await omniToken.mint(arbitrator2.address, mintAmount);
    await omniToken.mint(arbitrator3.address, mintAmount);

    // Approve arbitration contract
    await omniToken.connect(user1).approve(await arbitration.getAddress(), ethers.MaxUint256);
    await omniToken.connect(user2).approve(await arbitration.getAddress(), ethers.MaxUint256);
    await omniToken.connect(arbitrator1).approve(await arbitration.getAddress(), ethers.MaxUint256);
    await omniToken.connect(arbitrator2).approve(await arbitration.getAddress(), ethers.MaxUint256);
    await omniToken.connect(arbitrator3).approve(await arbitration.getAddress(), ethers.MaxUint256);

    // Approve privacy fee manager
    await omniToken.connect(user1).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(user2).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);

    // Register arbitrators
    const minStake = ethers.parseUnits("1000", 6);
    const specializations = [1, 2]; // ESCROW, PAYMENT

    await arbitration.connect(arbitrator1).registerArbitrator(minStake, specializations);
    await arbitration.connect(arbitrator2).registerArbitrator(minStake, specializations);
    await arbitration.connect(arbitrator3).registerArbitrator(minStake, specializations);

    // Enable privacy preferences
    await omniToken.connect(user1).setPrivacyPreference(true);
    await omniToken.connect(user2).setPrivacyPreference(true);

    return {
      arbitration,
      omniToken,
      privacyFeeManager,
      mockEscrow,
      owner,
      user1,
      user2,
      arbitrator1,
      arbitrator2,
      arbitrator3
    };
  }

  describe("Public Dispute Creation (No Privacy)", function () {
    it("Should create public dispute without privacy fees", async function () {
      const { arbitration, user1, user2, mockEscrow } = await loadFixture(deployArbitrationFixture);

      const disputeAmount = ethers.parseUnits("1000", 6);
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_001"));

      // Create public dispute (no privacy)
      await expect(arbitration.connect(user1).createDispute(
        user2.address,
        disputeAmount,
        1, // ESCROW type
        escrowId,
        "Public dispute"
      )).to.emit(arbitration, "DisputeCreated");

      // Verify no privacy fee was collected
      const dispute = await arbitration.disputes(0);
      expect(dispute.plaintiff).to.equal(user1.address);
      expect(dispute.isPrivate).to.be.false;
    });

    it("Should handle multiple public disputes efficiently", async function () {
      const { arbitration, user1, user2 } = await loadFixture(deployArbitrationFixture);

      const disputeAmount = ethers.parseUnits("500", 6);
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_002"));

      // Create multiple public disputes
      for (let i = 0; i < 3; i++) {
        await arbitration.connect(user1).createDispute(
          user2.address,
          disputeAmount,
          1, // ESCROW type
          escrowId,
          `Public dispute ${i}`
        );
      }

      const disputeCount = await arbitration.disputeCount();
      expect(disputeCount).to.equal(3);
    });
  });

  describe("Private Dispute Creation (With Privacy)", function () {
    it("Should create private dispute with privacy credits", async function () {
      const { arbitration, privacyFeeManager, user1, user2 } = await loadFixture(deployArbitrationFixture);

      // Pre-deposit privacy credits
      const creditAmount = ethers.parseUnits("1000", 6);
      await privacyFeeManager.connect(user1).depositPrivacyCredits(creditAmount);

      const disputeAmount = ethers.parseUnits("1000", 6);
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_003"));

      // Calculate expected privacy fee
      const operationType = ethers.keccak256(ethers.toUtf8Bytes("ARBITRATION"));
      const expectedFee = await privacyFeeManager.calculatePrivacyFee(operationType, disputeAmount);

      const initialCredits = await privacyFeeManager.getPrivacyCredits(user1.address);

      // Create private dispute
      await expect(arbitration.connect(user1).createDisputeWithPrivacy(
        user2.address,
        disputeAmount,
        1, // ESCROW type
        escrowId,
        "Private dispute",
        true // use privacy
      )).to.emit(arbitration, "DisputeCreated");

      // Verify privacy credits were deducted
      const finalCredits = await privacyFeeManager.getPrivacyCredits(user1.address);
      expect(initialCredits - finalCredits).to.equal(expectedFee);

      // Verify dispute is marked as private
      const dispute = await arbitration.disputes(0);
      expect(dispute.isPrivate).to.be.true;
    });

    it("Should fail if insufficient privacy credits", async function () {
      const { arbitration, privacyFeeManager, user1, user2 } = await loadFixture(deployArbitrationFixture);

      // Deposit small amount of credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("1", 6));

      const disputeAmount = ethers.parseUnits("10000", 6); // Large amount
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_004"));

      // Attempt to create private dispute
      await expect(
        arbitration.connect(user1).createDisputeWithPrivacy(
          user2.address,
          disputeAmount,
          1,
          escrowId,
          "Private dispute",
          true
        )
      ).to.be.revertedWith("Insufficient privacy credits");
    });

    it("Should allow private arbitrator assignment", async function () {
      const { arbitration, privacyFeeManager, user1, user2, arbitrator1 } = await loadFixture(deployArbitrationFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("1000", 6));

      const disputeAmount = ethers.parseUnits("1000", 6);
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_005"));

      // Create private dispute
      await arbitration.connect(user1).createDisputeWithPrivacy(
        user2.address,
        disputeAmount,
        1,
        escrowId,
        "Private dispute for assignment",
        true
      );

      // Assign arbitrator (should maintain privacy)
      await arbitration.assignArbitrator(0, arbitrator1.address);

      const dispute = await arbitration.disputes(0);
      expect(dispute.arbitrator).to.equal(arbitrator1.address);
      expect(dispute.isPrivate).to.be.true;
    });
  });

  describe("Privacy Edge Cases", function () {
    it("Should handle zero amount disputes", async function () {
      const { arbitration, user1, user2 } = await loadFixture(deployArbitrationFixture);

      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_006"));

      // Create dispute with zero amount (should still work)
      await expect(arbitration.connect(user1).createDispute(
        user2.address,
        0,
        1,
        escrowId,
        "Zero amount dispute"
      )).to.emit(arbitration, "DisputeCreated");
    });

    it("Should respect pause functionality", async function () {
      const { arbitration, user1, user2, owner } = await loadFixture(deployArbitrationFixture);

      // Pause contract
      await arbitration.connect(owner).pause();

      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_007"));

      // Try to create dispute while paused
      await expect(
        arbitration.connect(user1).createDispute(
          user2.address,
          ethers.parseUnits("1000", 6),
          1,
          escrowId,
          "Paused dispute"
        )
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should handle private dispute resolution", async function () {
      const { arbitration, privacyFeeManager, user1, user2, arbitrator1 } = await loadFixture(deployArbitrationFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("1000", 6));

      const disputeAmount = ethers.parseUnits("1000", 6);
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_008"));

      // Create private dispute
      await arbitration.connect(user1).createDisputeWithPrivacy(
        user2.address,
        disputeAmount,
        1,
        escrowId,
        "Private dispute for resolution",
        true
      );

      // Assign arbitrator
      await arbitration.assignArbitrator(0, arbitrator1.address);

      // Submit confidential decision
      const encryptedDecision = ethers.keccak256(ethers.toUtf8Bytes("CONFIDENTIAL_DECISION"));
      await arbitration.connect(arbitrator1).submitDecision(0, 1, encryptedDecision);

      const dispute = await arbitration.disputes(0);
      expect(dispute.status).to.equal(2); // RESOLVED
      expect(dispute.isPrivate).to.be.true;
    });
  });

  describe("Privacy Statistics", function () {
    it("Should track privacy usage correctly", async function () {
      const { arbitration, privacyFeeManager, user1, user2 } = await loadFixture(deployArbitrationFixture);

      // Pre-deposit credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      // Create mix of public and private disputes
      for (let i = 0; i < 3; i++) {
        const escrowId = ethers.keccak256(ethers.toUtf8Bytes(`ESCROW_${i}`));
        
        if (i % 2 === 0) {
          // Public dispute
          await arbitration.connect(user1).createDispute(
            user2.address,
            ethers.parseUnits("500", 6),
            1,
            escrowId,
            `Public dispute ${i}`
          );
        } else {
          // Private dispute
          await arbitration.connect(user1).createDisputeWithPrivacy(
            user2.address,
            ethers.parseUnits("500", 6),
            1,
            escrowId,
            `Private dispute ${i}`,
            true
          );
        }
      }

      // Check privacy statistics
      const stats = await privacyFeeManager.getUserPrivacyStats(user1.address);
      expect(stats.usage).to.be.gt(0); // Should have used privacy at least once
    });
  });

  describe("Multi-party Private Disputes", function () {
    it("Should handle panel assignment for private disputes", async function () {
      const { arbitration, privacyFeeManager, user1, user2, arbitrator1, arbitrator2, arbitrator3, owner } = 
        await loadFixture(deployArbitrationFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      const disputeAmount = ethers.parseUnits("5000", 6); // Complex dispute amount
      const escrowId = ethers.keccak256(ethers.toUtf8Bytes("ESCROW_COMPLEX"));

      // Create private complex dispute
      await arbitration.connect(user1).createDisputeWithPrivacy(
        user2.address,
        disputeAmount,
        1,
        escrowId,
        "Complex private dispute",
        true
      );

      // Assign panel for complex dispute
      await arbitration.connect(owner).assignArbitrationPanel(
        0,
        [arbitrator1.address, arbitrator2.address, arbitrator3.address]
      );

      const dispute = await arbitration.disputes(0);
      expect(dispute.status).to.equal(1); // IN_PROGRESS
      expect(dispute.isPrivate).to.be.true;
      
      // Verify panel assignment
      const panel = await arbitration.getArbitrationPanel(0);
      expect(panel.length).to.equal(3);
    });
  });
});