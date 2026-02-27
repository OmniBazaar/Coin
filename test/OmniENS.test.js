const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniENS Test Suite
 * @notice Comprehensive tests for the on-chain username registry
 * @dev Tests cover:
 *   1. Initialization (constructor, default fee)
 *   2. Name validation (length, characters, hyphens)
 *   3. Registration (fee payment, expiry, events, reverse lookup)
 *   4. Transfer (owner only, reverse record update)
 *   5. Renewal (extend from expiry, cap at MAX_DURATION)
 *   6. Resolution (forward, reverse, expired names)
 *   7. Availability (registered, expired, unknown)
 *   8. Admin (setRegistrationFee)
 *   9. Edge cases (re-register expired name, zero-fee registration)
 */
describe("OmniENS", function () {
  let ens, xom;
  let owner, oddaoTreasury, user1, user2, user3;

  const MIN_DURATION = 30 * 24 * 60 * 60; // 30 days
  const MAX_DURATION = 365 * 24 * 60 * 60; // 365 days
  const FEE_PER_YEAR = ethers.parseEther("10"); // 10 XOM

  beforeEach(async function () {
    [owner, oddaoTreasury, user1, user2, user3] =
      await ethers.getSigners();

    // Deploy mock XOM token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();

    // Deploy OmniENS
    const OmniENS = await ethers.getContractFactory("OmniENS");
    ens = await OmniENS.deploy(
      await xom.getAddress(),
      oddaoTreasury.address
    );
    await ens.waitForDeployment();

    // Mint tokens to users and approve
    const mintAmount = ethers.parseEther("10000");
    await xom.mint(user1.address, mintAmount);
    await xom.mint(user2.address, mintAmount);
    await xom.mint(user3.address, mintAmount);
    await xom
      .connect(user1)
      .approve(await ens.getAddress(), mintAmount);
    await xom
      .connect(user2)
      .approve(await ens.getAddress(), mintAmount);
    await xom
      .connect(user3)
      .approve(await ens.getAddress(), mintAmount);
  });

  // ─────────────────────────────────────────────────────────────────
  //  1. Initialization
  // ─────────────────────────────────────────────────────────────────

  describe("Initialization", function () {
    it("should set XOM token address", async function () {
      expect(await ens.xomToken()).to.equal(await xom.getAddress());
    });

    it("should set ODDAO treasury address", async function () {
      expect(await ens.oddaoTreasury()).to.equal(
        oddaoTreasury.address
      );
    });

    it("should set default registration fee to 10 XOM/year", async function () {
      expect(await ens.registrationFeePerYear()).to.equal(
        FEE_PER_YEAR
      );
    });

    it("should set correct constants", async function () {
      expect(await ens.MIN_NAME_LENGTH()).to.equal(3);
      expect(await ens.MAX_NAME_LENGTH()).to.equal(32);
      expect(await ens.MIN_DURATION()).to.equal(MIN_DURATION);
      expect(await ens.MAX_DURATION()).to.equal(MAX_DURATION);
    });

    it("should start with 0 total registrations", async function () {
      expect(await ens.totalRegistrations()).to.equal(0);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  2. Name Validation
  // ─────────────────────────────────────────────────────────────────

  describe("Name Validation", function () {
    it("should reject names shorter than 3 characters", async function () {
      await expect(
        ens.connect(user1).register("ab", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });

    it("should reject names longer than 32 characters", async function () {
      const longName = "a".repeat(33);
      await expect(
        ens.connect(user1).register(longName, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });

    it("should reject names with uppercase letters", async function () {
      await expect(
        ens.connect(user1).register("Alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with spaces", async function () {
      await expect(
        ens.connect(user1).register("my name", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with leading hyphens", async function () {
      await expect(
        ens.connect(user1).register("-abc", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with trailing hyphens", async function () {
      await expect(
        ens.connect(user1).register("abc-", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should accept valid names with hyphens", async function () {
      await ens.connect(user1).register("my-name", MIN_DURATION);
      expect(await ens.resolve("my-name")).to.equal(user1.address);
    });

    it("should accept valid names with numbers", async function () {
      await ens.connect(user1).register("user123", MIN_DURATION);
      expect(await ens.resolve("user123")).to.equal(user1.address);
    });

    it("should accept 3-character names", async function () {
      await ens.connect(user1).register("abc", MIN_DURATION);
      expect(await ens.resolve("abc")).to.equal(user1.address);
    });

    it("should accept 32-character names", async function () {
      const name = "a".repeat(32);
      await ens.connect(user1).register(name, MIN_DURATION);
      expect(await ens.resolve(name)).to.equal(user1.address);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  3. Registration
  // ─────────────────────────────────────────────────────────────────

  describe("Registration", function () {
    it("should register a name successfully", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      expect(await ens.resolve("alice")).to.equal(user1.address);
    });

    it("should emit NameRegistered event", async function () {
      await expect(
        ens.connect(user1).register("alice", MIN_DURATION)
      ).to.emit(ens, "NameRegistered");
    });

    it("should charge proportional fee for 30 days", async function () {
      const expectedFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);
      const before = await xom.balanceOf(oddaoTreasury.address);
      await ens.connect(user1).register("alice", MIN_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);
      expect(after - before).to.equal(expectedFee);
    });

    it("should charge proportional fee for 365 days", async function () {
      const before = await xom.balanceOf(oddaoTreasury.address);
      await ens.connect(user1).register("alice", MAX_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);
      expect(after - before).to.equal(FEE_PER_YEAR);
    });

    it("should set correct expiry timestamp", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      // Expiry should be approximately now + MIN_DURATION
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MIN_DURATION),
        5
      );
    });

    it("should set reverse record", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      expect(await ens.reverseResolve(user1.address)).to.equal(
        "alice"
      );
    });

    it("should increment total registrations", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      expect(await ens.totalRegistrations()).to.equal(1);
      await ens.connect(user2).register("bob", MIN_DURATION);
      expect(await ens.totalRegistrations()).to.equal(2);
    });

    it("should reject duplicate name registration", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      await expect(
        ens.connect(user2).register("alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "NameTaken");
    });

    it("should reject duration below minimum", async function () {
      await expect(
        ens.connect(user1).register("alice", MIN_DURATION - 1)
      ).to.be.revertedWithCustomError(ens, "DurationTooShort");
    });

    it("should reject duration above maximum", async function () {
      await expect(
        ens.connect(user1).register("alice", MAX_DURATION + 1)
      ).to.be.revertedWithCustomError(ens, "DurationTooLong");
    });

    it("should calculate fee correctly", async function () {
      const fee = await ens.calculateFee(MIN_DURATION);
      const expected =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);
      expect(fee).to.equal(expected);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  4. Transfer
  // ─────────────────────────────────────────────────────────────────

  describe("Transfer", function () {
    beforeEach(async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
    });

    it("should transfer name to new owner", async function () {
      await ens.connect(user1).transfer("alice", user2.address);
      expect(await ens.resolve("alice")).to.equal(user2.address);
    });

    it("should emit NameTransferred event", async function () {
      await expect(
        ens.connect(user1).transfer("alice", user2.address)
      )
        .to.emit(ens, "NameTransferred")
        .withArgs("alice", user1.address, user2.address);
    });

    it("should update reverse records on transfer", async function () {
      await ens.connect(user1).transfer("alice", user2.address);
      expect(await ens.reverseResolve(user1.address)).to.equal("");
      expect(await ens.reverseResolve(user2.address)).to.equal(
        "alice"
      );
    });

    it("should reject transfer by non-owner", async function () {
      await expect(
        ens.connect(user2).transfer("alice", user3.address)
      ).to.be.revertedWithCustomError(ens, "NotNameOwner");
    });

    it("should reject transfer to zero address", async function () {
      await expect(
        ens.connect(user1).transfer("alice", ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        ens,
        "ZeroRegistrationAddress"
      );
    });

    it("should reject transfer of expired name", async function () {
      await time.increase(MIN_DURATION + 1);
      await expect(
        ens.connect(user1).transfer("alice", user2.address)
      ).to.be.revertedWithCustomError(ens, "NameNotFound");
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  5. Renewal
  // ─────────────────────────────────────────────────────────────────

  describe("Renewal", function () {
    beforeEach(async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
    });

    it("should renew before expiry", async function () {
      const regBefore = await ens.getRegistration("alice");
      await ens
        .connect(user1)
        .renew("alice", MIN_DURATION);
      const regAfter = await ens.getRegistration("alice");
      expect(regAfter.expiresAt).to.be.gt(regBefore.expiresAt);
    });

    it("should emit NameRenewed event", async function () {
      await expect(
        ens.connect(user1).renew("alice", MIN_DURATION)
      ).to.emit(ens, "NameRenewed");
    });

    it("should renew after expiry (extends from now)", async function () {
      await time.increase(MIN_DURATION + 1);
      await ens
        .connect(user1)
        .renew("alice", MIN_DURATION);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      // Should be approximately now + MIN_DURATION
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MIN_DURATION),
        5
      );
    });

    it("should cap renewal at MAX_DURATION from now", async function () {
      // Register for MAX_DURATION, then try to renew another 30 days
      await ens.connect(user2).register("bob", MAX_DURATION);
      await ens
        .connect(user2)
        .renew("bob", MIN_DURATION);
      const reg = await ens.getRegistration("bob");
      const latest = await time.latest();
      // Should be capped at now + MAX_DURATION
      expect(reg.expiresAt).to.be.lte(
        BigInt(latest) + BigInt(MAX_DURATION) + 5n
      );
    });

    it("should reject renewal by non-owner", async function () {
      await expect(
        ens.connect(user2).renew("alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "NotNameOwner");
    });

    it("should reject renewal with duration below minimum", async function () {
      await expect(
        ens
          .connect(user1)
          .renew("alice", MIN_DURATION - 1)
      ).to.be.revertedWithCustomError(ens, "DurationTooShort");
    });

    it("should charge proportional fee for renewal", async function () {
      const expectedFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);
      const before = await xom.balanceOf(oddaoTreasury.address);
      await ens
        .connect(user1)
        .renew("alice", MIN_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);
      expect(after - before).to.equal(expectedFee);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  6. Resolution
  // ─────────────────────────────────────────────────────────────────

  describe("Resolution", function () {
    beforeEach(async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
    });

    it("should resolve registered name to owner", async function () {
      expect(await ens.resolve("alice")).to.equal(user1.address);
    });

    it("should return zero address for expired name", async function () {
      await time.increase(MIN_DURATION + 1);
      expect(await ens.resolve("alice")).to.equal(ethers.ZeroAddress);
    });

    it("should return zero address for unregistered name", async function () {
      expect(await ens.resolve("unknown")).to.equal(
        ethers.ZeroAddress
      );
    });

    it("should reverse resolve active name", async function () {
      expect(await ens.reverseResolve(user1.address)).to.equal(
        "alice"
      );
    });

    it("should return empty string for expired reverse record", async function () {
      await time.increase(MIN_DURATION + 1);
      expect(await ens.reverseResolve(user1.address)).to.equal("");
    });

    it("should return empty string for no reverse record", async function () {
      expect(await ens.reverseResolve(user3.address)).to.equal("");
    });

    it("should return full registration details", async function () {
      const reg = await ens.getRegistration("alice");
      expect(reg.owner).to.equal(user1.address);
      expect(reg.registeredAt).to.be.gt(0);
      expect(reg.expiresAt).to.be.gt(reg.registeredAt);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  7. Availability
  // ─────────────────────────────────────────────────────────────────

  describe("Availability", function () {
    it("should be available if never registered", async function () {
      expect(await ens.isAvailable("alice")).to.be.true;
    });

    it("should not be available if registered and active", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      expect(await ens.isAvailable("alice")).to.be.false;
    });

    it("should be available after expiry", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      expect(await ens.isAvailable("alice")).to.be.true;
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  8. Admin Functions
  // ─────────────────────────────────────────────────────────────────

  describe("Admin Functions", function () {
    it("should update registration fee", async function () {
      const newFee = ethers.parseEther("20");
      await ens.connect(owner).setRegistrationFee(newFee);
      expect(await ens.registrationFeePerYear()).to.equal(newFee);
    });

    it("should emit FeeUpdated event", async function () {
      const newFee = ethers.parseEther("20");
      await expect(ens.connect(owner).setRegistrationFee(newFee))
        .to.emit(ens, "FeeUpdated")
        .withArgs(FEE_PER_YEAR, newFee);
    });

    it("should reject fee update from non-owner", async function () {
      await expect(
        ens.connect(user1).setRegistrationFee(ethers.parseEther("5"))
      ).to.be.revertedWithCustomError(ens, "OwnableUnauthorizedAccount");
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  9. Edge Cases
  // ─────────────────────────────────────────────────────────────────

  describe("Edge Cases", function () {
    it("should allow re-registration of expired name", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      await ens.connect(user2).register("alice", MIN_DURATION);
      expect(await ens.resolve("alice")).to.equal(user2.address);
    });

    it("should clear old reverse record on re-registration", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      await ens.connect(user2).register("alice", MIN_DURATION);
      expect(await ens.reverseResolve(user1.address)).to.equal("");
      expect(await ens.reverseResolve(user2.address)).to.equal(
        "alice"
      );
    });

    it("should allow zero fee registration when fee is 0", async function () {
      await ens.connect(owner).setRegistrationFee(0);
      await ens.connect(user1).register("alice", MIN_DURATION);
      expect(await ens.resolve("alice")).to.equal(user1.address);
    });

    it("should allow a user to own multiple names but only one reverse", async function () {
      await ens.connect(user1).register("alice", MIN_DURATION);
      await ens.connect(user1).register("alice2", MIN_DURATION);
      // Reverse record points to last registered
      expect(await ens.reverseResolve(user1.address)).to.equal(
        "alice2"
      );
      // But both forward resolve to user1
      expect(await ens.resolve("alice")).to.equal(user1.address);
      expect(await ens.resolve("alice2")).to.equal(user1.address);
    });
  });
});
