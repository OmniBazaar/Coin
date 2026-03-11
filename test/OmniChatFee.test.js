const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniChatFee Test Suite
 * @notice Comprehensive tests for the chat fee management contract
 * @dev Tests cover:
 *   1. Initialization (constructor, constants, feeVault immutable)
 *   2. Free tier (20 messages/month tracking)
 *   3. Paid messages (fee collection, single transfer to feeVault)
 *   4. Bulk messages (10x fee)
 *   5. Fee distribution (100% to feeVault)
 *   6. Payment proofs (hasValidPayment)
 *   7. View functions (freeMessagesRemaining, nextMessageIndex)
 *   8. Admin functions (setBaseFee)
 *   9. Edge cases (month boundary reset, zero fee)
 */
describe("OmniChatFee", function () {
  let chatFee, xom;
  let owner, feeVault, validator1, validator2;
  let user1, user2;

  const BASE_FEE = ethers.parseEther("0.001"); // 0.001 XOM
  const FREE_TIER_LIMIT = 20;
  const BULK_MULTIPLIER = 10;

  beforeEach(async function () {
    [owner, feeVault, validator1, validator2, user1, user2] =
      await ethers.getSigners();

    // Deploy mock XOM token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();

    // Deploy OmniChatFee (4 params: xomToken, feeVault, baseFee, trustedForwarder)
    const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
    chatFee = await OmniChatFee.deploy(
      await xom.getAddress(),
      feeVault.address,
      BASE_FEE,
      ethers.ZeroAddress
    );
    await chatFee.waitForDeployment();

    // Mint tokens to users and approve
    const mintAmount = ethers.parseEther("100");
    await xom.mint(user1.address, mintAmount);
    await xom.mint(user2.address, mintAmount);
    await xom
      .connect(user1)
      .approve(await chatFee.getAddress(), mintAmount);
    await xom
      .connect(user2)
      .approve(await chatFee.getAddress(), mintAmount);
  });

  // -----------------------------------------------------------------
  //  1. Initialization
  // -----------------------------------------------------------------

  describe("Initialization", function () {
    it("should set XOM token address", async function () {
      expect(await chatFee.xomToken()).to.equal(
        await xom.getAddress()
      );
    });

    it("should set feeVault address", async function () {
      expect(await chatFee.feeVault()).to.equal(
        feeVault.address
      );
    });

    it("should set base fee", async function () {
      expect(await chatFee.baseFee()).to.equal(BASE_FEE);
    });

    it("should have correct constants", async function () {
      expect(await chatFee.FREE_TIER_LIMIT()).to.equal(20);
      expect(await chatFee.BULK_FEE_MULTIPLIER()).to.equal(10);
      expect(await chatFee.MIN_FEE()).to.equal(BigInt(1e15));
    });

    it("should reject zero token address", async function () {
      const OmniChatFee =
        await ethers.getContractFactory("OmniChatFee");
      await expect(
        OmniChatFee.deploy(
          ethers.ZeroAddress,
          feeVault.address,
          BASE_FEE,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });

    it("should reject zero feeVault address", async function () {
      const OmniChatFee =
        await ethers.getContractFactory("OmniChatFee");
      await expect(
        OmniChatFee.deploy(
          await xom.getAddress(),
          ethers.ZeroAddress,
          BASE_FEE,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });

    it("should reject zero base fee", async function () {
      const OmniChatFee =
        await ethers.getContractFactory("OmniChatFee");
      await expect(
        OmniChatFee.deploy(
          await xom.getAddress(),
          feeVault.address,
          0,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(chatFee, "ZeroBaseFee");
    });
  });

  // -----------------------------------------------------------------
  //  2. Free Tier
  // -----------------------------------------------------------------

  describe("Free Tier", function () {
    const channelId = ethers.id("test-channel");

    it("should allow 20 free messages per month", async function () {
      for (let i = 0; i < 20; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }
      expect(await chatFee.freeMessagesRemaining(user1.address)).to.equal(0);
    });

    it("should emit FreeMessageUsed event", async function () {
      await expect(
        chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address)
      ).to.emit(chatFee, "FreeMessageUsed");
    });

    it("should report correct remaining free messages", async function () {
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(20);

      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(19);
    });

    it("should not charge XOM for free tier messages", async function () {
      const before = await xom.balanceOf(user1.address);
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      const after = await xom.balanceOf(user1.address);
      expect(after).to.equal(before);
    });

    it("should set payment proof for free messages", async function () {
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, channelId, 0)
      ).to.be.true;
    });

    it("should increment message index for free messages", async function () {
      expect(await chatFee.nextMessageIndex(user1.address)).to.equal(
        0
      );
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(await chatFee.nextMessageIndex(user1.address)).to.equal(
        1
      );
    });
  });

  // -----------------------------------------------------------------
  //  3. Paid Messages
  // -----------------------------------------------------------------

  describe("Paid Messages", function () {
    const channelId = ethers.id("test-channel");

    beforeEach(async function () {
      // Exhaust free tier
      for (let i = 0; i < 20; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }
    });

    it("should charge baseFee after free tier exhausted", async function () {
      const before = await xom.balanceOf(user1.address);
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      const after = await xom.balanceOf(user1.address);
      expect(before - after).to.equal(BASE_FEE);
    });

    it("should emit MessageFeePaid event for paid messages", async function () {
      await expect(
        chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address)
      )
        .to.emit(chatFee, "MessageFeePaid")
        .withArgs(
          user1.address,
          channelId,
          20, // Message index 20 (21st message)
          BASE_FEE,
          validator1.address
        );
    });

    it("should send 100% of fee to feeVault", async function () {
      const vaultBefore = await xom.balanceOf(feeVault.address);

      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);

      expect(await xom.balanceOf(feeVault.address)).to.equal(
        vaultBefore + BASE_FEE
      );
    });

    it("should not leave any fee balance in the contract after distribution", async function () {
      const contractBefore = await xom.balanceOf(await chatFee.getAddress());
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      const contractAfter = await xom.balanceOf(await chatFee.getAddress());
      // All fees are pushed out immediately, so contract balance should not increase
      expect(contractAfter).to.equal(contractBefore);
    });

    it("should increment totalFeesCollected", async function () {
      const before = await chatFee.totalFeesCollected();
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(await chatFee.totalFeesCollected()).to.equal(
        before + BASE_FEE
      );
    });

    it("should set payment proof for paid messages", async function () {
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, channelId, 20)
      ).to.be.true;
    });
  });

  // -----------------------------------------------------------------
  //  4. Bulk Messages
  // -----------------------------------------------------------------

  describe("Bulk Messages", function () {
    const channelId = ethers.id("bulk-channel");

    it("should charge 10x base fee for bulk messages", async function () {
      const expectedFee = BASE_FEE * BigInt(BULK_MULTIPLIER);
      const before = await xom.balanceOf(user1.address);
      await chatFee
        .connect(user1)
        .payBulkMessageFee(channelId, validator1.address);
      const after = await xom.balanceOf(user1.address);
      expect(before - after).to.equal(expectedFee);
    });

    it("should not use free tier for bulk messages", async function () {
      // Even with free tier available, bulk always charges
      const before = await xom.balanceOf(user1.address);
      await chatFee
        .connect(user1)
        .payBulkMessageFee(channelId, validator1.address);
      const after = await xom.balanceOf(user1.address);
      expect(before - after).to.be.gt(0);
    });

    it("should emit MessageFeePaid with bulk fee", async function () {
      const bulkFee = BASE_FEE * BigInt(BULK_MULTIPLIER);
      await expect(
        chatFee
          .connect(user1)
          .payBulkMessageFee(channelId, validator1.address)
      )
        .to.emit(chatFee, "MessageFeePaid")
        .withArgs(
          user1.address,
          channelId,
          0,
          bulkFee,
          validator1.address
        );
    });

    it("should send 100% of bulk fee to feeVault", async function () {
      const bulkFee = BASE_FEE * BigInt(BULK_MULTIPLIER);
      const vaultBefore = await xom.balanceOf(feeVault.address);

      await chatFee
        .connect(user1)
        .payBulkMessageFee(channelId, validator1.address);

      expect(await xom.balanceOf(feeVault.address)).to.equal(
        vaultBefore + bulkFee
      );
    });

    it("should reject zero channel ID", async function () {
      await expect(
        chatFee
          .connect(user1)
          .payBulkMessageFee(ethers.ZeroHash, validator1.address)
      ).to.be.revertedWithCustomError(chatFee, "InvalidChannelId");
    });

    it("should reject zero validator address", async function () {
      await expect(
        chatFee
          .connect(user1)
          .payBulkMessageFee(channelId, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });
  });

  // -----------------------------------------------------------------
  //  5. Fee Distribution (100% to feeVault)
  // -----------------------------------------------------------------

  describe("Fee Distribution", function () {
    const channelId = ethers.id("test-channel");

    beforeEach(async function () {
      // Exhaust free tier
      for (let i = 0; i < 20; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }
    });

    it("should send 100% of fee to feeVault on each paid message", async function () {
      const vaultBefore = await xom.balanceOf(feeVault.address);
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      const vaultAfter = await xom.balanceOf(feeVault.address);

      expect(vaultAfter - vaultBefore).to.equal(BASE_FEE);
    });

    it("should not send any fee to the contract itself", async function () {
      const contractBefore = await xom.balanceOf(await chatFee.getAddress());
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      const contractAfter = await xom.balanceOf(await chatFee.getAddress());
      expect(contractAfter).to.equal(contractBefore);
    });

    it("should distribute fees across multiple paid messages correctly", async function () {
      const vaultBefore = await xom.balanceOf(feeVault.address);

      // Send 3 paid messages
      for (let i = 0; i < 3; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }

      const totalFee = BASE_FEE * 3n;

      expect(await xom.balanceOf(feeVault.address)).to.equal(
        vaultBefore + totalFee
      );
    });

    it("should deduct exact fee amount from user for each paid message", async function () {
      const userBefore = await xom.balanceOf(user1.address);

      // Send 3 paid messages
      for (let i = 0; i < 3; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }

      const totalFee = BASE_FEE * 3n;
      const userAfter = await xom.balanceOf(user1.address);
      expect(userBefore - userAfter).to.equal(totalFee);
    });
  });

  // -----------------------------------------------------------------
  //  6. Payment Proofs
  // -----------------------------------------------------------------

  describe("Payment Proofs", function () {
    const channelId = ethers.id("proof-channel");

    it("should return true for paid message", async function () {
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, channelId, 0)
      ).to.be.true;
    });

    it("should return false for unpaid message", async function () {
      expect(
        await chatFee.hasValidPayment(user1.address, channelId, 0)
      ).to.be.false;
    });

    it("should return false for wrong channel", async function () {
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      const otherChannel = ethers.id("other-channel");
      expect(
        await chatFee.hasValidPayment(
          user1.address,
          otherChannel,
          0
        )
      ).to.be.false;
    });

    it("should return false for wrong index", async function () {
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, channelId, 1)
      ).to.be.false;
    });
  });

  // -----------------------------------------------------------------
  //  7. View Functions
  // -----------------------------------------------------------------

  describe("View Functions", function () {
    const channelId = ethers.id("view-channel");

    it("should return current month identifier", async function () {
      const month = await chatFee.currentMonth();
      expect(month).to.be.gt(0);
    });

    it("should return zero message index for new user", async function () {
      expect(await chatFee.nextMessageIndex(user2.address)).to.equal(
        0
      );
    });

    it("should reject zero channel ID for payMessageFee", async function () {
      await expect(
        chatFee
          .connect(user1)
          .payMessageFee(ethers.ZeroHash, validator1.address)
      ).to.be.revertedWithCustomError(chatFee, "InvalidChannelId");
    });

    it("should reject zero validator for payMessageFee", async function () {
      await expect(
        chatFee
          .connect(user1)
          .payMessageFee(channelId, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });
  });

  // -----------------------------------------------------------------
  //  8. Admin Functions
  // -----------------------------------------------------------------

  describe("Admin Functions", function () {
    it("should update base fee", async function () {
      const newFee = ethers.parseEther("0.002");
      await chatFee.connect(owner).setBaseFee(newFee);
      expect(await chatFee.baseFee()).to.equal(newFee);
    });

    it("should emit BaseFeeUpdated event", async function () {
      const newFee = ethers.parseEther("0.002");
      await expect(chatFee.connect(owner).setBaseFee(newFee))
        .to.emit(chatFee, "BaseFeeUpdated")
        .withArgs(BASE_FEE, newFee);
    });

    it("should reject setBaseFee from non-owner", async function () {
      await expect(
        chatFee
          .connect(user1)
          .setBaseFee(ethers.parseEther("0.002"))
      ).to.be.revertedWithCustomError(chatFee, "OwnableUnauthorizedAccount");
    });

    it("should reject setBaseFee with zero value", async function () {
      await expect(
        chatFee.connect(owner).setBaseFee(0)
      ).to.be.revertedWithCustomError(chatFee, "ZeroBaseFee");
    });
  });

  // -----------------------------------------------------------------
  //  9. Edge Cases
  // -----------------------------------------------------------------

  describe("Edge Cases", function () {
    const channelId = ethers.id("edge-channel");

    it("should reset free tier on new month boundary", async function () {
      // Use 10 free messages
      for (let i = 0; i < 10; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(10);

      // Advance 31 days (past month boundary)
      await time.increase(31 * 24 * 60 * 60);

      // Free tier should reset
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(20);
    });

    it("should track per-user message indices independently", async function () {
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      await chatFee
        .connect(user2)
        .payMessageFee(channelId, validator1.address);
      expect(await chatFee.nextMessageIndex(user1.address)).to.equal(
        1
      );
      expect(await chatFee.nextMessageIndex(user2.address)).to.equal(
        1
      );
    });

    it("should send fees to feeVault regardless of validator param", async function () {
      // Exhaust free tier for user1
      for (let i = 0; i < 20; i++) {
        await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);
      }

      const vaultBefore = await xom.balanceOf(feeVault.address);

      // Send paid message via validator1
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);
      // Send paid message via validator2
      await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator2.address);

      // feeVault receives 100% from both messages
      expect(await xom.balanceOf(feeVault.address)).to.equal(
        vaultBefore + BASE_FEE * 2n
      );
    });

    it("should handle messages across multiple channels", async function () {
      const ch1 = ethers.id("channel-1");
      const ch2 = ethers.id("channel-2");

      await chatFee
        .connect(user1)
        .payMessageFee(ch1, validator1.address);
      await chatFee
        .connect(user1)
        .payMessageFee(ch2, validator1.address);

      expect(
        await chatFee.hasValidPayment(user1.address, ch1, 0)
      ).to.be.true;
      expect(
        await chatFee.hasValidPayment(user1.address, ch2, 1)
      ).to.be.true;
      // Cross-channel check should fail
      expect(
        await chatFee.hasValidPayment(user1.address, ch1, 1)
      ).to.be.false;
    });
  });
});
