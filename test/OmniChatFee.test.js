const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniChatFee V2 Test Suite
 * @notice Comprehensive tests for participation-based chat fee contract
 * @dev Tests cover:
 *   1. Initialization (UUPS proxy, roles, tier config)
 *   2. Tier determination (score-based tier lookup)
 *   3. Free tier per score (5/20/100/500/unlimited)
 *   4. Paid messages per tier (25/10/5/1/0 XOM)
 *   5. Marketplace exemption (free, no quota impact)
 *   6. Bulk messages (10x excess fee)
 *   7. Score transitions (tier changes mid-month)
 *   8. Payment proofs
 *   9. View/query functions
 *  10. Admin functions (setTier, setParticipation, setFeeVault)
 *  11. Edge cases (month boundary, multi-user, multi-channel)
 *  12. Access control (roles, unauthorized)
 */
describe("OmniChatFee V2", function () {
  let chatFee, xom, participation;
  let owner, feeVault, validator1, validator2;
  let user1, user2, user3, admin, upgrader;

  const CHANNEL_ID = ethers.id("test-channel");
  const LISTING_ID = ethers.id("listing-001");
  const UNLIMITED = ethers.MaxUint256;

  beforeEach(async function () {
    [owner, feeVault, validator1, validator2,
      user1, user2, user3, admin, upgrader] =
      await ethers.getSigners();

    // Deploy mock XOM token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();

    // Deploy mock participation
    const MockParticipation = await ethers.getContractFactory("MockParticipation");
    participation = await MockParticipation.deploy();
    await participation.waitForDeployment();

    // Deploy OmniChatFee as UUPS proxy
    const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
    chatFee = await upgrades.deployProxy(
      OmniChatFee,
      [
        await xom.getAddress(),
        feeVault.address,
        await participation.getAddress()
      ],
      // M-02 remediation added an ERC-2771 trustedForwarder ctor arg;
      // ZeroAddress disables meta-tx relaying in unit tests.
      { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
    );
    await chatFee.waitForDeployment();

    // Mint tokens to users and approve
    const mintAmount = ethers.parseEther("10000");
    for (const u of [user1, user2, user3]) {
      await xom.mint(u.address, mintAmount);
      await xom.connect(u).approve(await chatFee.getAddress(), mintAmount);
    }
  });

  // -----------------------------------------------------------------
  //  1. Initialization
  // -----------------------------------------------------------------

  describe("Initialization", function () {
    it("should set XOM token address", async function () {
      expect(await chatFee.xomToken()).to.equal(await xom.getAddress());
    });

    it("should set feeVault address", async function () {
      expect(await chatFee.feeVault()).to.equal(feeVault.address);
    });

    it("should set participation contract", async function () {
      expect(await chatFee.participation()).to.equal(
        await participation.getAddress()
      );
    });

    it("should grant DEFAULT_ADMIN_ROLE to deployer", async function () {
      const DEFAULT_ADMIN = ethers.ZeroHash;
      expect(await chatFee.hasRole(DEFAULT_ADMIN, owner.address)).to.be.true;
    });

    it("should grant ADMIN_ROLE to deployer", async function () {
      const ADMIN_ROLE = await chatFee.ADMIN_ROLE();
      expect(await chatFee.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
    });

    it("should grant UPGRADER_ROLE to deployer", async function () {
      const UPGRADER_ROLE = await chatFee.UPGRADER_ROLE();
      expect(await chatFee.hasRole(UPGRADER_ROLE, owner.address)).to.be.true;
    });

    it("should have correct constants", async function () {
      expect(await chatFee.TIER_COUNT()).to.equal(5);
      expect(await chatFee.BULK_FEE_MULTIPLIER()).to.equal(10);
      expect(await chatFee.MIN_FEE()).to.equal(BigInt(1e15));
      expect(await chatFee.UNLIMITED()).to.equal(UNLIMITED);
    });

    it("should configure default tier 0 (Anonymous)", async function () {
      const [minScore, freePerMonth, excessFee] =
        await chatFee.getTierConfig(0);
      expect(minScore).to.equal(0);
      expect(freePerMonth).to.equal(5);
      expect(excessFee).to.equal(ethers.parseEther("25"));
    });

    it("should configure default tier 1 (Basic)", async function () {
      const [minScore, freePerMonth, excessFee] =
        await chatFee.getTierConfig(1);
      expect(minScore).to.equal(10);
      expect(freePerMonth).to.equal(20);
      expect(excessFee).to.equal(ethers.parseEther("10"));
    });

    it("should configure default tier 2 (Established)", async function () {
      const [minScore, freePerMonth, excessFee] =
        await chatFee.getTierConfig(2);
      expect(minScore).to.equal(25);
      expect(freePerMonth).to.equal(100);
      expect(excessFee).to.equal(ethers.parseEther("5"));
    });

    it("should configure default tier 3 (Trusted)", async function () {
      const [minScore, freePerMonth, excessFee] =
        await chatFee.getTierConfig(3);
      expect(minScore).to.equal(50);
      expect(freePerMonth).to.equal(500);
      expect(excessFee).to.equal(ethers.parseEther("1"));
    });

    it("should configure default tier 4 (Elite)", async function () {
      const [minScore, freePerMonth, excessFee] =
        await chatFee.getTierConfig(4);
      expect(minScore).to.equal(75);
      expect(freePerMonth).to.equal(UNLIMITED);
      expect(excessFee).to.equal(0);
    });

    it("should reject zero token address", async function () {
      const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
      await expect(
        upgrades.deployProxy(
          OmniChatFee,
          [ethers.ZeroAddress, feeVault.address, await participation.getAddress()],
          { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });

    it("should reject zero feeVault address", async function () {
      const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
      await expect(
        upgrades.deployProxy(
          OmniChatFee,
          [await xom.getAddress(), ethers.ZeroAddress, await participation.getAddress()],
          { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });

    it("should reject zero participation address", async function () {
      const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
      await expect(
        upgrades.deployProxy(
          OmniChatFee,
          [await xom.getAddress(), feeVault.address, ethers.ZeroAddress],
          { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });
  });

  // -----------------------------------------------------------------
  //  2. Tier Determination
  // -----------------------------------------------------------------

  describe("Tier Determination", function () {
    it("should return tier 0 for score 0", async function () {
      await participation.setScore(user1.address, 0);
      // Score 0 with defaultScore 0 => tier 0
      expect(await chatFee.getUserTier(user1.address)).to.equal(0);
    });

    it("should return tier 0 for score 9", async function () {
      await participation.setScore(user1.address, 9);
      expect(await chatFee.getUserTier(user1.address)).to.equal(0);
    });

    it("should return tier 1 for score 10", async function () {
      await participation.setScore(user1.address, 10);
      expect(await chatFee.getUserTier(user1.address)).to.equal(1);
    });

    it("should return tier 1 for score 24", async function () {
      await participation.setScore(user1.address, 24);
      expect(await chatFee.getUserTier(user1.address)).to.equal(1);
    });

    it("should return tier 2 for score 25", async function () {
      await participation.setScore(user1.address, 25);
      expect(await chatFee.getUserTier(user1.address)).to.equal(2);
    });

    it("should return tier 3 for score 50", async function () {
      await participation.setScore(user1.address, 50);
      expect(await chatFee.getUserTier(user1.address)).to.equal(3);
    });

    it("should return tier 4 for score 75", async function () {
      await participation.setScore(user1.address, 75);
      expect(await chatFee.getUserTier(user1.address)).to.equal(4);
    });

    it("should return tier 4 for score 100", async function () {
      await participation.setScore(user1.address, 100);
      expect(await chatFee.getUserTier(user1.address)).to.equal(4);
    });
  });

  // -----------------------------------------------------------------
  //  3. Free Tier Per Score
  // -----------------------------------------------------------------

  describe("Free Tier Per Score", function () {
    it("score 0: should allow 5 free messages", async function () {
      // defaultScore is 0 => tier 0 => 5 free
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(5);

      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(0);
    });

    it("score 15: should allow 20 free messages", async function () {
      await participation.setScore(user1.address, 15);
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(20);
    });

    it("score 30: should allow 100 free messages", async function () {
      await participation.setScore(user1.address, 30);
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(100);
    });

    it("score 60: should allow 500 free messages", async function () {
      await participation.setScore(user1.address, 60);
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(500);
    });

    it("score 80: should return UNLIMITED free messages", async function () {
      await participation.setScore(user1.address, 80);
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(UNLIMITED);
    });

    it("should not charge XOM during free tier", async function () {
      await participation.setScore(user1.address, 15); // tier 1, 20 free
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(await xom.balanceOf(user1.address)).to.equal(before);
    });

    it("should emit FreeMessageUsed with correct tier", async function () {
      await participation.setScore(user1.address, 30); // tier 2
      await expect(
        chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address)
      ).to.emit(chatFee, "FreeMessageUsed")
        .withArgs(user1.address, CHANNEL_ID, 0, 99, 2);
    });
  });

  // -----------------------------------------------------------------
  //  4. Paid Messages Per Tier
  // -----------------------------------------------------------------

  describe("Paid Messages Per Tier", function () {
    it("tier 0: should charge 25 XOM after 5 free", async function () {
      // defaultScore = 0 => tier 0
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      const after = await xom.balanceOf(user1.address);
      expect(before - after).to.equal(ethers.parseEther("25"));
    });

    it("tier 1: should charge 10 XOM after 20 free", async function () {
      await participation.setScore(user1.address, 15);
      for (let i = 0; i < 20; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(before - (await xom.balanceOf(user1.address))).to.equal(
        ethers.parseEther("10")
      );
    });

    it("tier 2: should charge 5 XOM after 100 free", async function () {
      await participation.setScore(user1.address, 30);
      for (let i = 0; i < 100; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(before - (await xom.balanceOf(user1.address))).to.equal(
        ethers.parseEther("5")
      );
    });

    it("tier 3: should charge 1 XOM after 500 free", async function () {
      await participation.setScore(user1.address, 60);
      for (let i = 0; i < 500; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(before - (await xom.balanceOf(user1.address))).to.equal(
        ethers.parseEther("1")
      );
    });

    it("tier 4: should never charge (unlimited free)", async function () {
      await participation.setScore(user1.address, 80);
      const before = await xom.balanceOf(user1.address);
      // Send many messages
      for (let i = 0; i < 50; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      expect(await xom.balanceOf(user1.address)).to.equal(before);
    });

    it("should send 100% of excess fee to feeVault", async function () {
      // tier 0, exhaust free
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      const vaultBefore = await xom.balanceOf(feeVault.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(await xom.balanceOf(feeVault.address)).to.equal(
        vaultBefore + ethers.parseEther("25")
      );
    });

    it("should emit MessageFeePaid with tier and fee", async function () {
      // tier 0, exhaust free
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      await expect(
        chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address)
      ).to.emit(chatFee, "MessageFeePaid")
        .withArgs(
          user1.address, CHANNEL_ID, validator1.address, 5,
          ethers.parseEther("25"), 0
        );
    });
  });

  // -----------------------------------------------------------------
  //  5. Marketplace Exemption
  // -----------------------------------------------------------------

  describe("Marketplace Exemption", function () {
    it("should not charge XOM for marketplace messages", async function () {
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      expect(await xom.balanceOf(user1.address)).to.equal(before);
    });

    it("should not increment monthly message count", async function () {
      const month = await chatFee.currentMonth();
      await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      expect(
        await chatFee.monthlyMessageCount(user1.address, month)
      ).to.equal(0);
    });

    it("should NOT record a paid-message proof (anti-spam bypass fix)", async function () {
      // A marketplace message is free and must NOT mint a `paymentProofs`
      // entry, otherwise any caller could forge a free paid-message proof
      // for an arbitrary channel and bypass the tier fee gate.
      await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      expect(
        await chatFee.hasValidPayment(user1.address, CHANNEL_ID, 0)
      ).to.be.false;
    });

    it("should record marketplace proof", async function () {
      await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      expect(
        await chatFee.isMarketplaceMessage(user1.address, LISTING_ID, 0)
      ).to.be.true;
    });

    it("should emit MarketplaceMessageSent", async function () {
      await expect(
        chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID)
      ).to.emit(chatFee, "MarketplaceMessageSent")
        .withArgs(user1.address, LISTING_ID, 0);
    });

    it("should increment totalMarketplaceMessages", async function () {
      await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      expect(await chatFee.totalMarketplaceMessages()).to.equal(1);
    });

    it("should reject zero listing ID", async function () {
      await expect(
        chatFee.connect(user1).payMarketplaceMessageFee(ethers.ZeroHash, CHANNEL_ID)
      ).to.be.revertedWithCustomError(chatFee, "InvalidListingId");
    });

    it("should reject zero channel ID", async function () {
      await expect(
        chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(chatFee, "InvalidChannelId");
    });

    it("marketplace messages should not affect free tier quota", async function () {
      // Send 10 marketplace messages
      for (let i = 0; i < 10; i++) {
        await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      }
      // Free tier should still be full (5 for tier 0)
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(5);
    });

    it("should increment message index for marketplace messages", async function () {
      await chatFee.connect(user1).payMarketplaceMessageFee(LISTING_ID, CHANNEL_ID);
      expect(await chatFee.nextMessageIndex(user1.address)).to.equal(1);
    });
  });

  // -----------------------------------------------------------------
  //  6. Bulk Messages
  // -----------------------------------------------------------------

  describe("Bulk Messages", function () {
    it("tier 0: should charge 250 XOM (25 * 10)", async function () {
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payBulkMessageFee(CHANNEL_ID, validator1.address);
      expect(before - (await xom.balanceOf(user1.address))).to.equal(
        ethers.parseEther("250")
      );
    });

    it("tier 4: should charge 0 for bulk (0 * 10 = 0)", async function () {
      await participation.setScore(user1.address, 80);
      const before = await xom.balanceOf(user1.address);
      await chatFee.connect(user1).payBulkMessageFee(CHANNEL_ID, validator1.address);
      expect(await xom.balanceOf(user1.address)).to.equal(before);
    });

    it("should always count toward monthly messages", async function () {
      const month = await chatFee.currentMonth();
      await chatFee.connect(user1).payBulkMessageFee(CHANNEL_ID, validator1.address);
      expect(
        await chatFee.monthlyMessageCount(user1.address, month)
      ).to.equal(1);
    });

    it("should reject zero channel ID", async function () {
      await expect(
        chatFee.connect(user1).payBulkMessageFee(ethers.ZeroHash, validator1.address)
      ).to.be.revertedWithCustomError(chatFee, "InvalidChannelId");
    });

    it("should reject zero validator", async function () {
      await expect(
        chatFee.connect(user1).payBulkMessageFee(CHANNEL_ID, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });
  });

  // -----------------------------------------------------------------
  //  7. Score Transitions
  // -----------------------------------------------------------------

  describe("Score Transitions", function () {
    it("should reflect tier upgrade immediately", async function () {
      // Start at tier 0
      expect(await chatFee.getUserTier(user1.address)).to.equal(0);

      // Upgrade to tier 2
      await participation.setScore(user1.address, 30);
      expect(await chatFee.getUserTier(user1.address)).to.equal(2);

      // Free messages should now reflect tier 2 (100)
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(100);
    });

    it("should use new excess fee after score change", async function () {
      // Start at tier 0 (25 XOM excess), exhaust free
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }

      // Upgrade to tier 2 (5 XOM excess)
      await participation.setScore(user1.address, 30);

      // Already used 5 messages, tier 2 has 100 free => 95 remaining
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(95);
    });

    it("should handle downgrade gracefully", async function () {
      await participation.setScore(user1.address, 80); // tier 4
      // Send some free messages
      for (let i = 0; i < 10; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }

      // Downgrade to tier 0
      await participation.setScore(user1.address, 5);
      // Already used 10, tier 0 gives 5 free => 0 remaining
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(0);
    });
  });

  // -----------------------------------------------------------------
  //  8. getUserFeeInfo
  // -----------------------------------------------------------------

  describe("getUserFeeInfo", function () {
    it("should return complete fee info for tier 0 user", async function () {
      const [tierIdx, freeRemaining, excessFee, monthlyUsed, score] =
        await chatFee.getUserFeeInfo(user1.address);
      expect(tierIdx).to.equal(0);
      expect(freeRemaining).to.equal(5);
      expect(excessFee).to.equal(ethers.parseEther("25"));
      expect(monthlyUsed).to.equal(0);
      expect(score).to.equal(0);
    });

    it("should return complete fee info for tier 4 user", async function () {
      await participation.setScore(user1.address, 90);
      const [tierIdx, freeRemaining, excessFee, monthlyUsed, score] =
        await chatFee.getUserFeeInfo(user1.address);
      expect(tierIdx).to.equal(4);
      expect(freeRemaining).to.equal(UNLIMITED);
      expect(excessFee).to.equal(0);
      expect(monthlyUsed).to.equal(0);
      expect(score).to.equal(90);
    });

    it("should reflect message usage", async function () {
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      const [, freeRemaining, , monthlyUsed] =
        await chatFee.getUserFeeInfo(user1.address);
      expect(freeRemaining).to.equal(4);
      expect(monthlyUsed).to.equal(1);
    });
  });

  // -----------------------------------------------------------------
  //  9. Payment Proofs
  // -----------------------------------------------------------------

  describe("Payment Proofs", function () {
    it("should return true for paid message", async function () {
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, CHANNEL_ID, 0)
      ).to.be.true;
    });

    it("should return false for unpaid message", async function () {
      expect(
        await chatFee.hasValidPayment(user1.address, CHANNEL_ID, 0)
      ).to.be.false;
    });

    it("should return false for wrong channel", async function () {
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, ethers.id("other"), 0)
      ).to.be.false;
    });

    it("should return false for wrong index", async function () {
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(
        await chatFee.hasValidPayment(user1.address, CHANNEL_ID, 999)
      ).to.be.false;
    });
  });

  // -----------------------------------------------------------------
  // 10. Admin Functions
  // -----------------------------------------------------------------

  describe("Admin Functions", function () {
    it("should update tier configuration", async function () {
      const ADMIN_ROLE = await chatFee.ADMIN_ROLE();
      await chatFee.connect(owner).setTier(
        0, 0, 10, ethers.parseEther("50")
      );
      const [minScore, freePerMonth, excessFee] =
        await chatFee.getTierConfig(0);
      expect(minScore).to.equal(0);
      expect(freePerMonth).to.equal(10);
      expect(excessFee).to.equal(ethers.parseEther("50"));
    });

    it("should emit TierUpdated event", async function () {
      await expect(
        chatFee.connect(owner).setTier(0, 0, 10, ethers.parseEther("50"))
      ).to.emit(chatFee, "TierUpdated")
        .withArgs(0, 0, 10, ethers.parseEther("50"));
    });

    it("should reject tier 0 with non-zero minScore", async function () {
      await expect(
        chatFee.connect(owner).setTier(0, 5, 10, ethers.parseEther("20"))
      ).to.be.revertedWithCustomError(chatFee, "InvalidTierConfig");
    });

    it("should reject out-of-order tier scores", async function () {
      // Tier 1 minScore must be > tier 0 minScore (0)
      await expect(
        chatFee.connect(owner).setTier(1, 0, 20, ethers.parseEther("10"))
      ).to.be.revertedWithCustomError(chatFee, "InvalidTierConfig");
    });

    it("should reject a non-final tier that inverts the next tier's minScore", async function () {
      // #15: the ascending upper-bound check must apply to ALL non-final
      // tiers. Tier 2 default minScore is 25 and tier 3 is 50. Setting
      // tier 2's minScore to 60 (>= tier 3's 50) inverts ordering and must
      // revert — regardless of the next tier's minScore being non-zero.
      await expect(
        chatFee.connect(owner).setTier(2, 60, 100, ethers.parseEther("5"))
      ).to.be.revertedWithCustomError(chatFee, "InvalidTierConfig");

      // Boundary: equal to next tier's minScore is also rejected (non-strict).
      await expect(
        chatFee.connect(owner).setTier(1, 25, 20, ethers.parseEther("10"))
      ).to.be.revertedWithCustomError(chatFee, "InvalidTierConfig");
    });

    it("should reject excess fee above maximum", async function () {
      await expect(
        chatFee.connect(owner).setTier(
          0, 0, 5, ethers.parseEther("1001")
        )
      ).to.be.revertedWithCustomError(chatFee, "FeeExceedsMaximum");
    });

    it("should reject invalid tier index", async function () {
      await expect(
        chatFee.connect(owner).setTier(5, 90, 1000, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(chatFee, "InvalidTierConfig");
    });

    it("should reject setTier from non-admin", async function () {
      await expect(
        chatFee.connect(user1).setTier(0, 0, 10, ethers.parseEther("50"))
      ).to.be.reverted;
    });

    it("should update participation contract", async function () {
      const MockP = await ethers.getContractFactory("MockParticipation");
      const newP = await MockP.deploy();
      await newP.waitForDeployment();

      await expect(
        chatFee.connect(owner).setParticipationContract(await newP.getAddress())
      ).to.emit(chatFee, "ParticipationContractUpdated");

      expect(await chatFee.participation()).to.equal(await newP.getAddress());
    });

    it("should reject zero participation address", async function () {
      await expect(
        chatFee.connect(owner).setParticipationContract(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });

    it("should update fee vault and emit event", async function () {
      const oldVault = await chatFee.feeVault();
      await expect(chatFee.connect(owner).setFeeVault(user3.address))
        .to.emit(chatFee, "FeeVaultUpdated")
        .withArgs(oldVault, user3.address);
      expect(await chatFee.feeVault()).to.equal(user3.address);
    });

    it("should reject zero fee vault", async function () {
      await expect(
        chatFee.connect(owner).setFeeVault(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });
  });

  // -----------------------------------------------------------------
  // 11. Edge Cases
  // -----------------------------------------------------------------

  describe("Edge Cases", function () {
    it("should reset free tier on new month boundary", async function () {
      // Use 3 free messages
      for (let i = 0; i < 3; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(2);

      // Advance 31 days. S-01 made the month epoch BLOCK-based
      // (block.number / MONTH_BLOCKS, 2s blocks), so roll the epoch by
      // mining past the boundary instead of advancing time.
      const monthBlocks = BigInt((30 * 24 * 60 * 60) / 2); // 1,296,000
      await ethers.provider.send("hardhat_mine", [
        "0x" + (monthBlocks + 1n).toString(16),
        "0x2",
      ]);

      // Free tier resets
      expect(
        await chatFee.freeMessagesRemaining(user1.address)
      ).to.equal(5);
    });

    it("should track per-user indices independently", async function () {
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      await chatFee.connect(user2).payMessageFee(CHANNEL_ID, validator1.address);
      expect(await chatFee.nextMessageIndex(user1.address)).to.equal(1);
      expect(await chatFee.nextMessageIndex(user2.address)).to.equal(1);
    });

    it("should handle messages across multiple channels", async function () {
      const ch1 = ethers.id("channel-1");
      const ch2 = ethers.id("channel-2");

      await chatFee.connect(user1).payMessageFee(ch1, validator1.address);
      await chatFee.connect(user1).payMessageFee(ch2, validator1.address);

      expect(await chatFee.hasValidPayment(user1.address, ch1, 0)).to.be.true;
      expect(await chatFee.hasValidPayment(user1.address, ch2, 1)).to.be.true;
      expect(await chatFee.hasValidPayment(user1.address, ch1, 1)).to.be.false;
    });

    it("should reject zero channel for payMessageFee", async function () {
      await expect(
        chatFee.connect(user1).payMessageFee(ethers.ZeroHash, validator1.address)
      ).to.be.revertedWithCustomError(chatFee, "InvalidChannelId");
    });

    it("should reject zero validator for payMessageFee", async function () {
      await expect(
        chatFee.connect(user1).payMessageFee(CHANNEL_ID, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });

    it("should track totalFeesCollected correctly", async function () {
      // Exhaust free tier (5 for tier 0)
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      }
      expect(await chatFee.totalFeesCollected()).to.equal(0);

      // Send 2 paid messages (25 XOM each)
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      await chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address);
      expect(await chatFee.totalFeesCollected()).to.equal(
        ethers.parseEther("50")
      );
    });

    it("getExcessFee should return correct fee per tier", async function () {
      expect(await chatFee.getExcessFee(user1.address)).to.equal(
        ethers.parseEther("25")
      );

      await participation.setScore(user1.address, 80);
      expect(await chatFee.getExcessFee(user1.address)).to.equal(0);
    });
  });

  // -----------------------------------------------------------------
  //  RT-OB-02 / RT-AC-04 regressions (2026-08-24 security sweep)
  // -----------------------------------------------------------------

  describe("Security sweep regressions", function () {
    it("RT-OB-02: a reverting scorer fails open to the Anonymous tier", async function () {
      await participation.setScore(user1.address, 80);
      expect(await chatFee.getUserTier(user1.address)).to.equal(4);

      // Break the scorer — messaging must still work, tiered as Anonymous.
      await participation.setRevertScores(true);
      expect(await chatFee.getUserTier(user1.address)).to.equal(0);

      // The actual pay path must not revert (fail-open, not fail-closed).
      await expect(
        chatFee.connect(user1).payMessageFee(CHANNEL_ID, validator1.address)
      ).to.not.be.reverted;

      // Restore for any later assertions in this file.
      await participation.setRevertScores(false);
    });

    it("RT-AC-04: exposes the post-multiplier bulk ceiling constant", async function () {
      expect(await chatFee.MAX_BULK_FEE()).to.equal(
        (await chatFee.MAX_EXCESS_FEE()) * 10n
      );
    });

    it("RT-AC-04: bulk fee charges exactly 10x the tier excess fee (capped)", async function () {
      // user1 (tier 0) excess fee = 25 XOM → bulk = 250 XOM.
      const before = await xom.balanceOf(feeVault.address);
      await chatFee.connect(user1).payBulkMessageFee(CHANNEL_ID, validator1.address);
      const after = await xom.balanceOf(feeVault.address);
      expect(after - before).to.equal(ethers.parseEther("250"));
    });
  });
});
