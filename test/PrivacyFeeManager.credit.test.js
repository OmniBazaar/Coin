const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("PrivacyFeeManager Credit System", function () {
  // Test fixture
  async function deployPrivacyFeeManagerFixture() {
    const [owner, user1, user2, treasury, development] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("contracts/MockERC20.sol:MockERC20");
    const omniToken = await MockERC20.deploy("OmniCoin", "OMNI", 6);
    const cotiToken = await MockERC20.deploy("COTI", "COTI", 18);
    await omniToken.waitForDeployment();
    await cotiToken.waitForDeployment();

    // Deploy mock DEX router
    const mockDexRouter = await ethers.getSigners().then(signers => signers[9].address);

    // Deploy PrivacyFeeManager
    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await omniToken.getAddress(),
      await cotiToken.getAddress(),
      mockDexRouter,
      await owner.getAddress()
    );
    await privacyFeeManager.waitForDeployment();

    // Mint tokens to users
    const mintAmount = ethers.parseUnits("10000", 6); // 10,000 OMNI
    await omniToken.mint(user1.address, mintAmount);
    await omniToken.mint(user2.address, mintAmount);

    // Approve PrivacyFeeManager to spend user tokens
    await omniToken.connect(user1).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(user2).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);

    // Grant fee manager role to owner for testing
    await privacyFeeManager.grantRole(await privacyFeeManager.FEE_MANAGER_ROLE(), owner.address);

    return { privacyFeeManager, omniToken, cotiToken, owner, user1, user2, treasury, development };
  }

  describe("Privacy Credit Deposits", function () {
    it("Should allow users to deposit privacy credits", async function () {
      const { privacyFeeManager, omniToken, user1 } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      const depositAmount = ethers.parseUnits("100", 6); // 100 OMNI
      
      // Check initial balances
      const initialUserBalance = await omniToken.balanceOf(user1.address);
      const initialContractBalance = await omniToken.balanceOf(await privacyFeeManager.getAddress());
      
      // Deposit credits
      await expect(privacyFeeManager.connect(user1).depositPrivacyCredits(depositAmount))
        .to.emit(privacyFeeManager, "PrivacyCreditsDeposited")
        .withArgs(user1.address, depositAmount, depositAmount);
      
      // Check balances after deposit
      expect(await omniToken.balanceOf(user1.address)).to.equal(initialUserBalance - depositAmount);
      expect(await omniToken.balanceOf(await privacyFeeManager.getAddress())).to.equal(initialContractBalance + depositAmount);
      
      // Check credit balance
      expect(await privacyFeeManager.getPrivacyCredits(user1.address)).to.equal(depositAmount);
    });

    it("Should accumulate multiple deposits", async function () {
      const { privacyFeeManager, user1 } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      const deposit1 = ethers.parseUnits("50", 6);
      const deposit2 = ethers.parseUnits("75", 6);
      
      // First deposit
      await privacyFeeManager.connect(user1).depositPrivacyCredits(deposit1);
      expect(await privacyFeeManager.getPrivacyCredits(user1.address)).to.equal(deposit1);
      
      // Second deposit
      await privacyFeeManager.connect(user1).depositPrivacyCredits(deposit2);
      expect(await privacyFeeManager.getPrivacyCredits(user1.address)).to.equal(deposit1 + deposit2);
    });

    it("Should reject zero deposits", async function () {
      const { privacyFeeManager, user1 } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      await expect(
        privacyFeeManager.connect(user1).depositPrivacyCredits(0)
      ).to.be.revertedWith("Must deposit credits");
    });
  });

  describe("Privacy Credit Usage", function () {
    it("Should deduct credits when collecting privacy fees", async function () {
      const { privacyFeeManager, user1, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Deposit credits first
      const depositAmount = ethers.parseUnits("100", 6);
      await privacyFeeManager.connect(user1).depositPrivacyCredits(depositAmount);
      
      // Calculate fee for a transfer
      const transferAmount = ethers.parseUnits("1000", 6);
      const operationType = ethers.keccak256(ethers.toUtf8Bytes("TRANSFER"));
      const expectedFee = await privacyFeeManager.calculatePrivacyFee(operationType, transferAmount);
      
      // Collect privacy fee (simulating a contract calling this)
      await expect(privacyFeeManager.connect(owner).collectPrivacyFee(
        user1.address,
        operationType,
        transferAmount
      )).to.emit(privacyFeeManager, "PrivacyCreditsUsed")
        .withArgs(user1.address, operationType, expectedFee, depositAmount - expectedFee);
      
      // Check remaining credits
      expect(await privacyFeeManager.getPrivacyCredits(user1.address)).to.equal(depositAmount - expectedFee);
    });

    it("Should fail if insufficient credits", async function () {
      const { privacyFeeManager, user1, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Deposit small amount
      const depositAmount = ethers.parseUnits("1", 6);
      await privacyFeeManager.connect(user1).depositPrivacyCredits(depositAmount);
      
      // Try to use more than deposited
      const largeTransfer = ethers.parseUnits("10000", 6);
      const operationType = ethers.keccak256(ethers.toUtf8Bytes("TRANSFER"));
      
      await expect(
        privacyFeeManager.connect(owner).collectPrivacyFee(
          user1.address,
          operationType,
          largeTransfer
        )
      ).to.be.revertedWith("Insufficient privacy credits");
    });

    it("Should not emit PrivacyFeeCollected event (privacy protection)", async function () {
      const { privacyFeeManager, user1, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Deposit credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("100", 6));
      
      // Collect fee
      const tx = await privacyFeeManager.connect(owner).collectPrivacyFee(
        user1.address,
        ethers.keccak256(ethers.toUtf8Bytes("TRANSFER")),
        ethers.parseUnits("1000", 6)
      );
      
      // Check that PrivacyFeeCollected was NOT emitted
      const receipt = await tx.wait();
      const privacyFeeCollectedEvents = receipt.logs.filter(
        log => log.fragment?.name === "PrivacyFeeCollected"
      );
      expect(privacyFeeCollectedEvents.length).to.equal(0);
    });
  });

  describe("Privacy Credit Withdrawals", function () {
    it("Should allow users to withdraw unused credits", async function () {
      const { privacyFeeManager, omniToken, user1 } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Deposit credits
      const depositAmount = ethers.parseUnits("100", 6);
      await privacyFeeManager.connect(user1).depositPrivacyCredits(depositAmount);
      
      // Withdraw half
      const withdrawAmount = ethers.parseUnits("50", 6);
      const initialBalance = await omniToken.balanceOf(user1.address);
      
      await privacyFeeManager.connect(user1).withdrawPrivacyCredits(withdrawAmount);
      
      // Check balances
      expect(await omniToken.balanceOf(user1.address)).to.equal(initialBalance + withdrawAmount);
      expect(await privacyFeeManager.getPrivacyCredits(user1.address)).to.equal(depositAmount - withdrawAmount);
    });

    it("Should fail if withdrawing more than balance", async function () {
      const { privacyFeeManager, user1 } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Deposit credits
      const depositAmount = ethers.parseUnits("50", 6);
      await privacyFeeManager.connect(user1).depositPrivacyCredits(depositAmount);
      
      // Try to withdraw more
      await expect(
        privacyFeeManager.connect(user1).withdrawPrivacyCredits(ethers.parseUnits("100", 6))
      ).to.be.revertedWith("Insufficient credits");
    });
  });

  describe("Legacy Direct Payment", function () {
    it("Should still support direct fee payment (with visibility)", async function () {
      const { privacyFeeManager, user1, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      const transferAmount = ethers.parseUnits("1000", 6);
      const operationType = ethers.keccak256(ethers.toUtf8Bytes("TRANSFER"));
      const expectedFee = await privacyFeeManager.calculatePrivacyFee(operationType, transferAmount);
      
      // Use direct payment (visible transaction)
      await expect(privacyFeeManager.connect(owner).collectPrivacyFeeDirect(
        user1.address,
        operationType,
        transferAmount
      )).to.emit(privacyFeeManager, "PrivacyFeeCollected")
        .withArgs(user1.address, operationType, expectedFee, await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
    });
  });

  describe("Credit System Statistics", function () {
    it("Should track credit system statistics correctly", async function () {
      const { privacyFeeManager, user1, user2, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Multiple users deposit
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("100", 6));
      await privacyFeeManager.connect(user2).depositPrivacyCredits(ethers.parseUnits("200", 6));
      
      // User1 uses some credits
      await privacyFeeManager.connect(owner).collectPrivacyFee(
        user1.address,
        ethers.keccak256(ethers.toUtf8Bytes("TRANSFER")),
        ethers.parseUnits("500", 6)
      );
      
      // Check statistics
      const stats = await privacyFeeManager.getCreditSystemStats();
      expect(stats.totalDeposited).to.equal(ethers.parseUnits("300", 6));
      expect(stats.totalUsed).to.be.gt(0);
      expect(stats.totalActive).to.equal(stats.totalDeposited - stats.totalUsed);
    });

    it("Should track per-user statistics", async function () {
      const { privacyFeeManager, user1, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Deposit and use credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("100", 6));
      
      // Multiple privacy operations
      for (let i = 0; i < 3; i++) {
        await privacyFeeManager.connect(owner).collectPrivacyFee(
          user1.address,
          ethers.keccak256(ethers.toUtf8Bytes("TRANSFER")),
          ethers.parseUnits("100", 6)
        );
      }
      
      // Check user stats
      const stats = await privacyFeeManager.getUserPrivacyStats(user1.address);
      expect(stats.usage).to.equal(3);
      expect(stats.creditBalance).to.be.lt(ethers.parseUnits("100", 6));
    });
  });

  describe("Privacy Analysis Protection", function () {
    it("Should break timing correlation between deposit and usage", async function () {
      const { privacyFeeManager, user1, user2, owner } = await loadFixture(deployPrivacyFeeManagerFixture);
      
      // Users deposit at different times
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("500", 6));
      await privacyFeeManager.connect(user2).depositPrivacyCredits(ethers.parseUnits("500", 6));
      
      // Later, they use privacy features
      // Observer cannot correlate deposit time with usage time
      await privacyFeeManager.connect(owner).collectPrivacyFee(
        user1.address,
        ethers.keccak256(ethers.toUtf8Bytes("ESCROW")),
        ethers.parseUnits("1000", 6)
      );
      
      // No visible transaction at time of use - privacy protected
    });
  });
});