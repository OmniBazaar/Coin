const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniENS Test Suite
 * @notice Comprehensive tests for the on-chain username registry
 * @dev Tests cover:
 *   1. Initialization (constructor, default fee, zero-address rejection)
 *   2. Name validation (length, characters, hyphens)
 *   3. System registration (owner-only, free, at-signup path)
 *   4. Renewal (extend from expiry, cap at MAX_DURATION, M-01 fee fix)
 *   5. Resolution (forward, reverse, expired names)
 *   6. Availability (registered, system-reserved, unknown)
 *   7. Admin (setRegistrationFee, fee bounds L-03)
 *   8. Edge cases (re-register expired, multiple names, overwrite event)
 *   9. System renewal (owner only, no fee)
 *
 * @dev Public register() and transfer() were REMOVED (founder directive
 *      2026-08-03): names are only provided to new users at signup via
 *      systemRegister(), and users cannot transfer their names. There is
 *      no commit-reveal machinery anymore.
 */
describe("OmniENS", function () {
  let ens, xom;
  let owner, feeVault, user1, user2, user3;

  const MIN_DURATION = 30 * 24 * 60 * 60; // 30 days
  const MAX_DURATION = 365 * 24 * 60 * 60; // 365 days
  const FEE_PER_YEAR = ethers.parseEther("1000"); // 1000 XOM

  /**
   * Helper: system-register a name (owner only, free, at-signup path).
   * This is the ONLY way names are created now.
   *
   * @param {string} name - Username to register
   * @param {object} nameOwner - Address that will own the name
   * @param {number} duration - Registration duration in seconds
   * @returns {Promise<object>} The systemRegister() transaction
   */
  async function systemRegister(name, nameOwner, duration) {
    return ens.connect(owner).systemRegister(name, nameOwner.address, duration);
  }

  beforeEach(async function () {
    [owner, feeVault, user1, user2, user3] =
      await ethers.getSigners();

    // Deploy mock XOM token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();

    // Deploy OmniENS (3 constructor params: xom, feeVault, trustedForwarder)
    const OmniENS = await ethers.getContractFactory("OmniENS");
    ens = await OmniENS.deploy(
      await xom.getAddress(),
      feeVault.address,
      ethers.ZeroAddress // trustedForwarder_ (disabled)
    );
    await ens.waitForDeployment();

    // Mint tokens to users and approve (enough for 1000 XOM/yr renewal fees)
    const mintAmount = ethers.parseEther("100000");
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

  // -------------------------------------------------------------------
  //  1. Initialization
  // -------------------------------------------------------------------

  describe("Initialization", function () {
    it("should set XOM token address", async function () {
      expect(await ens.xomToken()).to.equal(await xom.getAddress());
    });

    it("should set fee vault address", async function () {
      expect(await ens.feeVault()).to.equal(
        feeVault.address
      );
    });

    it("should set default registration fee to 1000 XOM/year", async function () {
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

    it("should set fee bound constants", async function () {
      expect(await ens.MIN_REGISTRATION_FEE()).to.equal(
        ethers.parseEther("1")
      );
      expect(await ens.MAX_REGISTRATION_FEE()).to.equal(
        ethers.parseEther("1000")
      );
    });

    it("should start with 0 total registrations", async function () {
      expect(await ens.totalRegistrations()).to.equal(0);
    });

    it("should reject zero XOM token address in constructor", async function () {
      const OmniENS = await ethers.getContractFactory("OmniENS");
      await expect(
        OmniENS.deploy(
          ethers.ZeroAddress,
          feeVault.address,
          ethers.ZeroAddress // trustedForwarder_ (disabled)
        )
      ).to.be.revertedWithCustomError(ens, "ZeroAddress");
    });

    it("should reject zero fee vault address in constructor", async function () {
      const OmniENS = await ethers.getContractFactory("OmniENS");
      await expect(
        OmniENS.deploy(
          await xom.getAddress(),
          ethers.ZeroAddress,
          ethers.ZeroAddress // trustedForwarder_ (disabled)
        )
      ).to.be.revertedWithCustomError(ens, "ZeroAddress");
    });
  });

  // -------------------------------------------------------------------
  //  2. Name Validation
  // -------------------------------------------------------------------

  describe("Name Validation", function () {
    // Name validation runs inside systemRegister() via _validateName(),
    // so these tests exercise the same rules through the at-signup path.

    it("should reject names shorter than 3 characters", async function () {
      await expect(
        systemRegister("ab", user1, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });

    it("should reject names longer than 32 characters", async function () {
      const longName = "a".repeat(33);
      await expect(
        systemRegister(longName, user1, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });

    it("should reject names with uppercase letters", async function () {
      await expect(
        systemRegister("Alice", user1, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with spaces", async function () {
      await expect(
        systemRegister("my name", user1, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with leading hyphens", async function () {
      await expect(
        systemRegister("-abc", user1, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with trailing hyphens", async function () {
      await expect(
        systemRegister("abc-", user1, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should accept valid names with hyphens", async function () {
      await systemRegister("my-name", user1, MIN_DURATION);
      expect(await ens.resolve("my-name")).to.equal(user1.address);
    });

    it("should accept valid names with numbers", async function () {
      await systemRegister("user123", user1, MIN_DURATION);
      expect(await ens.resolve("user123")).to.equal(user1.address);
    });

    it("should accept 3-character names", async function () {
      await systemRegister("abc", user1, MIN_DURATION);
      expect(await ens.resolve("abc")).to.equal(user1.address);
    });

    it("should accept 32-character names", async function () {
      const name = "a".repeat(32);
      await systemRegister(name, user1, MIN_DURATION);
      expect(await ens.resolve(name)).to.equal(user1.address);
    });
  });

  // -------------------------------------------------------------------
  //  3. System Registration (auto-register at signup)
  // -------------------------------------------------------------------

  describe("System Registration", function () {
    it("should register a name for a user (owner only)", async function () {
      await systemRegister("alice", user1, MAX_DURATION);
      expect(await ens.resolve("alice")).to.equal(user1.address);
    });

    it("should emit SystemNameRegistered event", async function () {
      await expect(
        systemRegister("alice", user1, MAX_DURATION)
      ).to.emit(ens, "SystemNameRegistered");
    });

    it("should not charge any fee", async function () {
      const vaultBefore = await xom.balanceOf(feeVault.address);
      await systemRegister("alice", user1, MAX_DURATION);
      const vaultAfter = await xom.balanceOf(feeVault.address);
      expect(vaultAfter).to.equal(vaultBefore);
    });

    it("should set reverse record", async function () {
      await systemRegister("alice", user1, MAX_DURATION);
      expect(await ens.reverseResolve(user1.address)).to.equal(
        "alice"
      );
    });

    it("should mark name as systemRegistered", async function () {
      const nameHash = ethers.keccak256(ethers.toUtf8Bytes("alice"));
      await systemRegister("alice", user1, MAX_DURATION);
      expect(await ens.systemRegistered(nameHash)).to.be.true;
    });

    it("should increment totalRegistrations", async function () {
      const before = await ens.totalRegistrations();
      await systemRegister("alice", user1, MAX_DURATION);
      expect(await ens.totalRegistrations()).to.equal(before + 1n);
    });

    it("should cap duration to MAX_DURATION", async function () {
      const hugeD = MAX_DURATION * 10;
      await systemRegister("alice", user1, hugeD);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MAX_DURATION),
        5
      );
    });

    it("should floor duration to MIN_DURATION", async function () {
      await systemRegister("alice", user1, 1);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MIN_DURATION),
        5
      );
    });

    it("should reject from non-owner", async function () {
      await expect(
        ens
          .connect(user1)
          .systemRegister("alice", user1.address, MAX_DURATION)
      ).to.be.revertedWithCustomError(
        ens,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should reject zero address owner", async function () {
      await expect(
        ens
          .connect(owner)
          .systemRegister("alice", ethers.ZeroAddress, MAX_DURATION)
      ).to.be.revertedWithCustomError(ens, "ZeroAddress");
    });

    it("should allow owner to reassign an active system name", async function () {
      // The old public register() path is gone, so every active name is
      // system-registered. The owner may re-register an active system name
      // to a new user (systemRegister is the only registration path).
      await systemRegister("alice", user1, MAX_DURATION);
      await systemRegister("alice", user2, MAX_DURATION);
      expect(await ens.resolve("alice")).to.equal(user2.address);
    });

    it("should allow re-registration of own system name (renewal)", async function () {
      await systemRegister("alice", user1, MIN_DURATION);
      // Wait for expiry
      await time.increase(MIN_DURATION + 1);
      // Re-register same system name for a new owner
      await systemRegister("alice", user2, MAX_DURATION);
      expect(await ens.resolve("alice")).to.equal(user2.address);
    });

    it("should not double-count totalRegistrations on re-register", async function () {
      await systemRegister("alice", user1, MIN_DURATION);
      const countAfterFirst = await ens.totalRegistrations();
      await time.increase(MIN_DURATION + 1);
      await systemRegister("alice", user1, MAX_DURATION);
      expect(await ens.totalRegistrations()).to.equal(
        countAfterFirst
      );
    });

    it("should validate name format", async function () {
      await expect(
        systemRegister("AB", user1, MAX_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });
  });

  // -------------------------------------------------------------------
  //  4. Renewal
  // -------------------------------------------------------------------

  describe("Renewal", function () {
    beforeEach(async function () {
      await systemRegister("alice", user1, MIN_DURATION);
    });

    it("should renew before expiry", async function () {
      const regBefore = await ens.getRegistration("alice");
      await ens.connect(user1).renew("alice", MIN_DURATION);
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
      await ens.connect(user1).renew("alice", MIN_DURATION);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      // Should be approximately now + MIN_DURATION
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MIN_DURATION),
        5
      );
    });

    it("should cap renewal at MAX_DURATION from now", async function () {
      // Register "bob" for MAX_DURATION, then try to renew
      await systemRegister("bob", user2, MAX_DURATION);
      await ens.connect(user2).renew("bob", MIN_DURATION);
      const reg = await ens.getRegistration("bob");
      const latest = await time.latest();
      // Should be capped at now + MAX_DURATION
      expect(reg.expiresAt).to.be.lte(
        BigInt(latest) + BigInt(MAX_DURATION) + 5n
      );
    });

    it("should charge fee based on actual duration after cap (M-01)", async function () {
      // Register "bob" for MAX_DURATION
      await systemRegister("bob", user2, MAX_DURATION);

      // Renew with MIN_DURATION, but since bob already has MAX_DURATION
      // from registration, the actual added time may be capped.
      // Track fee received by feeVault.
      const vaultBefore = await xom.balanceOf(feeVault.address);

      await ens.connect(user2).renew("bob", MIN_DURATION);

      const vaultAfter = await xom.balanceOf(feeVault.address);
      const totalReceived = vaultAfter - vaultBefore;

      // Fee should be based on actual duration added, which may be
      // less than MIN_DURATION due to MAX_DURATION cap
      const fullMinFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);

      // The actual total fee should be <= the full fee for MIN_DURATION
      expect(totalReceived).to.be.lte(fullMinFee);
    });

    it("should reject renewal by non-owner", async function () {
      await expect(
        ens.connect(user2).renew("alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "NotNameOwner");
    });

    it("should reject renewal with duration below minimum", async function () {
      await expect(
        ens.connect(user1).renew("alice", MIN_DURATION - 1)
      ).to.be.revertedWithCustomError(ens, "DurationTooShort");
    });

    it("should send proportional fee for renewal to feeVault", async function () {
      const totalFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);

      const vaultBefore = await xom.balanceOf(feeVault.address);

      await ens.connect(user1).renew("alice", MIN_DURATION);

      const vaultAfter = await xom.balanceOf(feeVault.address);

      expect(vaultAfter - vaultBefore).to.equal(totalFee);
    });
  });

  // -------------------------------------------------------------------
  //  5. Resolution
  // -------------------------------------------------------------------

  describe("Resolution", function () {
    beforeEach(async function () {
      await systemRegister("alice", user1, MIN_DURATION);
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

  // -------------------------------------------------------------------
  //  6. Availability
  // -------------------------------------------------------------------

  describe("Availability", function () {
    it("should be available if never registered", async function () {
      expect(await ens.isAvailable("alice")).to.be.true;
    });

    it("should not be available if registered and active", async function () {
      await systemRegister("alice", user1, MIN_DURATION);
      expect(await ens.isAvailable("alice")).to.be.false;
    });

    it("should not be available for expired system names", async function () {
      // M-01: isAvailable returns false for ALL system-registered names,
      // regardless of expiry. System names are never available to anyone.
      await systemRegister("alice", user1, MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      expect(await ens.isAvailable("alice")).to.be.false;
    });
  });

  // -------------------------------------------------------------------
  //  7. Admin Functions
  // -------------------------------------------------------------------

  describe("Admin Functions", function () {
    it("should update registration fee", async function () {
      const newFee = ethers.parseEther("20");
      await ens.connect(owner).setRegistrationFee(newFee);
      expect(await ens.registrationFeePerYear()).to.equal(newFee);
    });

    it("should emit RegistrationFeeUpdated event", async function () {
      const newFee = ethers.parseEther("20");
      await expect(ens.connect(owner).setRegistrationFee(newFee))
        .to.emit(ens, "RegistrationFeeUpdated")
        .withArgs(FEE_PER_YEAR, newFee);
    });

    it("should reject fee update from non-owner", async function () {
      await expect(
        ens
          .connect(user1)
          .setRegistrationFee(ethers.parseEther("5"))
      ).to.be.revertedWithCustomError(
        ens,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should reject fee below minimum (L-03)", async function () {
      // MIN_REGISTRATION_FEE = 1 ether (1 XOM)
      const tooLow = ethers.parseEther("0.5");
      await expect(
        ens.connect(owner).setRegistrationFee(tooLow)
      ).to.be.revertedWithCustomError(ens, "FeeOutOfBounds");
    });

    it("should reject zero fee (L-03)", async function () {
      await expect(
        ens.connect(owner).setRegistrationFee(0)
      ).to.be.revertedWithCustomError(ens, "FeeOutOfBounds");
    });

    it("should reject fee above maximum (L-03)", async function () {
      // MAX_REGISTRATION_FEE = 1000 ether (1000 XOM)
      const tooHigh = ethers.parseEther("1001");
      await expect(
        ens.connect(owner).setRegistrationFee(tooHigh)
      ).to.be.revertedWithCustomError(ens, "FeeOutOfBounds");
    });

    it("should accept fee at minimum bound", async function () {
      const minFee = ethers.parseEther("1");
      await ens.connect(owner).setRegistrationFee(minFee);
      expect(await ens.registrationFeePerYear()).to.equal(minFee);
    });

    it("should accept fee at maximum bound", async function () {
      const maxFee = ethers.parseEther("1000");
      await ens.connect(owner).setRegistrationFee(maxFee);
      expect(await ens.registrationFeePerYear()).to.equal(maxFee);
    });

    it("should use Ownable2Step (L-02)", async function () {
      // Verify two-step ownership transfer is required
      await ens.connect(owner).transferOwnership(user1.address);
      // user1 is pending but not yet owner
      await expect(
        ens
          .connect(user1)
          .setRegistrationFee(ethers.parseEther("5"))
      ).to.be.revertedWithCustomError(
        ens,
        "OwnableUnauthorizedAccount"
      );
      // Accept ownership
      await ens.connect(user1).acceptOwnership();
      // Now user1 is owner
      const newFee = ethers.parseEther("5");
      await ens.connect(user1).setRegistrationFee(newFee);
      expect(await ens.registrationFeePerYear()).to.equal(newFee);
    });
  });

  // -------------------------------------------------------------------
  //  8. Edge Cases
  // -------------------------------------------------------------------

  describe("Edge Cases", function () {
    it("should allow re-registration of expired name via systemRegister", async function () {
      await systemRegister("alice", user1, MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      await systemRegister("alice", user2, MIN_DURATION);
      expect(await ens.resolve("alice")).to.equal(user2.address);
    });

    it("should clear old reverse record on re-registration", async function () {
      await systemRegister("alice", user1, MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      await systemRegister("alice", user2, MIN_DURATION);
      expect(await ens.reverseResolve(user1.address)).to.equal("");
      expect(await ens.reverseResolve(user2.address)).to.equal(
        "alice"
      );
    });

    it("should allow a user to own multiple names but only one reverse", async function () {
      await systemRegister("alice", user1, MIN_DURATION);
      await systemRegister("alice2", user1, MIN_DURATION);
      // Reverse record points to last registered
      expect(await ens.reverseResolve(user1.address)).to.equal(
        "alice2"
      );
      // But both forward resolve to user1
      expect(await ens.resolve("alice")).to.equal(user1.address);
      expect(await ens.resolve("alice2")).to.equal(user1.address);
    });

    it("should emit ReverseRecordOverwritten when overwriting active reverse (M-03)", async function () {
      // Register first name
      await systemRegister("alice", user1, MIN_DURATION);

      // Register second name for the same user - should emit overwrite event
      await expect(
        systemRegister("alice2", user1, MIN_DURATION)
      ).to.emit(ens, "ReverseRecordOverwritten");
    });

    it("should not emit ReverseRecordOverwritten for first registration", async function () {
      await expect(
        systemRegister("alice", user1, MIN_DURATION)
      ).to.not.emit(ens, "ReverseRecordOverwritten");
    });
  });

  // -------------------------------------------------------------------
  //  9. System Renewal
  // -------------------------------------------------------------------

  describe("System Renewal", function () {
    beforeEach(async function () {
      await systemRegister("alice", user1, MIN_DURATION);
    });

    it("should renew a system name (no fee)", async function () {
      const regBefore = await ens.getRegistration("alice");
      const vaultBefore = await xom.balanceOf(feeVault.address);

      await ens
        .connect(owner)
        .systemRenew("alice", MIN_DURATION);

      const regAfter = await ens.getRegistration("alice");
      const vaultAfter = await xom.balanceOf(feeVault.address);

      expect(regAfter.expiresAt).to.be.gt(regBefore.expiresAt);
      expect(vaultAfter).to.equal(vaultBefore); // No fee
    });

    it("should emit NameRenewed event", async function () {
      await expect(
        ens.connect(owner).systemRenew("alice", MIN_DURATION)
      ).to.emit(ens, "NameRenewed");
    });

    it("should renew after expiry (extends from now)", async function () {
      await time.increase(MIN_DURATION + 1);
      await ens
        .connect(owner)
        .systemRenew("alice", MIN_DURATION);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MIN_DURATION),
        5
      );
    });

    it("should cap renewal at MAX_DURATION from now", async function () {
      await ens
        .connect(owner)
        .systemRenew("alice", MAX_DURATION * 2);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      expect(reg.expiresAt).to.be.lte(
        BigInt(latest) + BigInt(MAX_DURATION) + 5n
      );
    });

    it("should reject from non-owner", async function () {
      await expect(
        ens.connect(user1).systemRenew("alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(
        ens,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should reject for never-registered names", async function () {
      await expect(
        ens.connect(owner).systemRenew("never-registered", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "NameNotFound");
    });
  });
});
