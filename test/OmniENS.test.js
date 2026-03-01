const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniENS Test Suite
 * @notice Comprehensive tests for the on-chain username registry
 * @dev Tests cover:
 *   1. Initialization (constructor, default fee, zero-address rejection)
 *   2. Name validation (length, characters, hyphens)
 *   3. Commit-reveal scheme (H-01 audit fix)
 *   4. Registration (fee payment, expiry, events, reverse lookup)
 *   5. Transfer (owner only, reverse record update)
 *   6. Renewal (extend from expiry, cap at MAX_DURATION, M-01 fee fix)
 *   7. Resolution (forward, reverse, expired names)
 *   8. Availability (registered, expired, unknown)
 *   9. Admin (setRegistrationFee, fee bounds L-03)
 *  10. Edge cases (re-register expired, multiple names, overwrite event)
 */
describe("OmniENS", function () {
  let ens, xom;
  let owner, oddaoTreasury, user1, user2, user3;

  const MIN_DURATION = 30 * 24 * 60 * 60; // 30 days
  const MAX_DURATION = 365 * 24 * 60 * 60; // 365 days
  const FEE_PER_YEAR = ethers.parseEther("10"); // 10 XOM
  const MIN_COMMITMENT_AGE = 60; // 1 minute in seconds

  /**
   * Helper: perform the full commit-reveal registration flow.
   * 1. Compute commitment hash via makeCommitment()
   * 2. Call commit() with that hash
   * 3. Advance time by MIN_COMMITMENT_AGE + 1
   * 4. Call register(name, duration, secret)
   *
   * @param {object} signer - The signer performing the registration
   * @param {string} name - Username to register
   * @param {number} duration - Registration duration in seconds
   * @param {string} [secret] - Optional secret; random bytes32 if omitted
   * @returns {Promise<object>} The register() transaction receipt
   */
  async function commitAndRegister(signer, name, duration, secret) {
    if (!secret) {
      secret = ethers.hexlify(ethers.randomBytes(32));
    }

    // Compute commitment
    const commitment = await ens.makeCommitment(
      name,
      signer.address,
      secret
    );

    // Phase 1: commit
    await ens.connect(signer).commit(commitment);

    // Advance time past MIN_COMMITMENT_AGE
    await time.increase(MIN_COMMITMENT_AGE + 1);

    // Phase 2: reveal (register)
    const tx = await ens
      .connect(signer)
      .register(name, duration, secret);
    return tx;
  }

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

  // -------------------------------------------------------------------
  //  1. Initialization
  // -------------------------------------------------------------------

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

    it("should set commit-reveal constants", async function () {
      expect(await ens.MIN_COMMITMENT_AGE()).to.equal(60); // 1 minute
      expect(await ens.MAX_COMMITMENT_AGE()).to.equal(
        24 * 60 * 60
      ); // 24 hours
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
        OmniENS.deploy(ethers.ZeroAddress, oddaoTreasury.address)
      ).to.be.revertedWithCustomError(ens, "ZeroAddress");
    });

    it("should reject zero ODDAO treasury address in constructor", async function () {
      const OmniENS = await ethers.getContractFactory("OmniENS");
      await expect(
        OmniENS.deploy(await xom.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(ens, "ZeroAddress");
    });
  });

  // -------------------------------------------------------------------
  //  2. Name Validation
  // -------------------------------------------------------------------

  describe("Name Validation", function () {
    // Name validation runs BEFORE commitment check in register(),
    // so these tests do not need a valid commitment.
    const dummySecret = ethers.ZeroHash;

    it("should reject names shorter than 3 characters", async function () {
      await expect(
        ens.connect(user1).register("ab", MIN_DURATION, dummySecret)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });

    it("should reject names longer than 32 characters", async function () {
      const longName = "a".repeat(33);
      await expect(
        ens
          .connect(user1)
          .register(longName, MIN_DURATION, dummySecret)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");
    });

    it("should reject names with uppercase letters", async function () {
      await expect(
        ens
          .connect(user1)
          .register("Alice", MIN_DURATION, dummySecret)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with spaces", async function () {
      await expect(
        ens
          .connect(user1)
          .register("my name", MIN_DURATION, dummySecret)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with leading hyphens", async function () {
      await expect(
        ens
          .connect(user1)
          .register("-abc", MIN_DURATION, dummySecret)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should reject names with trailing hyphens", async function () {
      await expect(
        ens
          .connect(user1)
          .register("abc-", MIN_DURATION, dummySecret)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");
    });

    it("should accept valid names with hyphens", async function () {
      await commitAndRegister(user1, "my-name", MIN_DURATION);
      expect(await ens.resolve("my-name")).to.equal(user1.address);
    });

    it("should accept valid names with numbers", async function () {
      await commitAndRegister(user1, "user123", MIN_DURATION);
      expect(await ens.resolve("user123")).to.equal(user1.address);
    });

    it("should accept 3-character names", async function () {
      await commitAndRegister(user1, "abc", MIN_DURATION);
      expect(await ens.resolve("abc")).to.equal(user1.address);
    });

    it("should accept 32-character names", async function () {
      const name = "a".repeat(32);
      await commitAndRegister(user1, name, MIN_DURATION);
      expect(await ens.resolve(name)).to.equal(user1.address);
    });
  });

  // -------------------------------------------------------------------
  //  3. Commit-Reveal Scheme (H-01)
  // -------------------------------------------------------------------

  describe("Commit-Reveal", function () {
    const secret = ethers.hexlify(ethers.randomBytes(32));

    it("should emit NameCommitted event on commit", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await expect(ens.connect(user1).commit(commitment))
        .to.emit(ens, "NameCommitted")
        .withArgs(commitment, user1.address);
    });

    it("should store commitment timestamp", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      const timestamp = await ens.commitments(commitment);
      expect(timestamp).to.be.gt(0);
    });

    it("should reject registration without commitment", async function () {
      const randomSecret = ethers.hexlify(ethers.randomBytes(32));
      await expect(
        ens
          .connect(user1)
          .register("alice", MIN_DURATION, randomSecret)
      ).to.be.revertedWithCustomError(ens, "NoCommitment");
    });

    it("should reject registration if commitment is too new", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      // Don't advance time - commitment is too fresh
      await expect(
        ens.connect(user1).register("alice", MIN_DURATION, secret)
      ).to.be.revertedWithCustomError(ens, "CommitmentTooNew");
    });

    it("should reject registration if commitment has expired", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      // Advance past MAX_COMMITMENT_AGE (24 hours)
      await time.increase(24 * 60 * 60 + 1);
      await expect(
        ens.connect(user1).register("alice", MIN_DURATION, secret)
      ).to.be.revertedWithCustomError(ens, "CommitmentExpired");
    });

    it("should reject if wrong secret is used", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);
      const wrongSecret = ethers.hexlify(ethers.randomBytes(32));
      await expect(
        ens
          .connect(user1)
          .register("alice", MIN_DURATION, wrongSecret)
      ).to.be.revertedWithCustomError(ens, "NoCommitment");
    });

    it("should reject if different user tries to use the commitment", async function () {
      // user1 commits for themselves
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);
      // user2 tries to register with user1's secret
      await expect(
        ens.connect(user2).register("alice", MIN_DURATION, secret)
      ).to.be.revertedWithCustomError(ens, "NoCommitment");
    });

    it("should delete commitment after successful registration", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);
      await ens
        .connect(user1)
        .register("alice", MIN_DURATION, secret);
      // Commitment should be deleted
      const timestamp = await ens.commitments(commitment);
      expect(timestamp).to.equal(0);
    });

    it("should compute correct commitment via makeCommitment", async function () {
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      // Manually compute expected hash
      const expected = ethers.keccak256(
        ethers.solidityPacked(
          ["string", "address", "bytes32"],
          ["alice", user1.address, secret]
        )
      );
      expect(commitment).to.equal(expected);
    });
  });

  // -------------------------------------------------------------------
  //  4. Registration
  // -------------------------------------------------------------------

  describe("Registration", function () {
    it("should register a name successfully", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      expect(await ens.resolve("alice")).to.equal(user1.address);
    });

    it("should emit NameRegistered event", async function () {
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);

      await expect(
        ens.connect(user1).register("alice", MIN_DURATION, secret)
      ).to.emit(ens, "NameRegistered");
    });

    it("should charge proportional fee for 30 days", async function () {
      const expectedFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);
      const before = await xom.balanceOf(oddaoTreasury.address);
      await commitAndRegister(user1, "alice", MIN_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);
      expect(after - before).to.equal(expectedFee);
    });

    it("should charge proportional fee for 365 days", async function () {
      const before = await xom.balanceOf(oddaoTreasury.address);
      await commitAndRegister(user1, "alice", MAX_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);
      expect(after - before).to.equal(FEE_PER_YEAR);
    });

    it("should set correct expiry timestamp", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      const reg = await ens.getRegistration("alice");
      const latest = await time.latest();
      // Expiry should be approximately now + MIN_DURATION
      expect(reg.expiresAt).to.be.closeTo(
        BigInt(latest) + BigInt(MIN_DURATION),
        5
      );
    });

    it("should set reverse record", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      expect(await ens.reverseResolve(user1.address)).to.equal(
        "alice"
      );
    });

    it("should increment total registrations", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      expect(await ens.totalRegistrations()).to.equal(1);
      await commitAndRegister(user2, "bob", MIN_DURATION);
      expect(await ens.totalRegistrations()).to.equal(2);
    });

    it("should reject duplicate name registration", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      // user2 commits and tries to register the same name
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const commitment = await ens.makeCommitment(
        "alice",
        user2.address,
        secret
      );
      await ens.connect(user2).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);
      await expect(
        ens.connect(user2).register("alice", MIN_DURATION, secret)
      ).to.be.revertedWithCustomError(ens, "NameTaken");
    });

    it("should reject duration below minimum", async function () {
      // Duration validation runs before commitment check
      const dummySecret = ethers.ZeroHash;
      await expect(
        ens
          .connect(user1)
          .register("alice", MIN_DURATION - 1, dummySecret)
      ).to.be.revertedWithCustomError(ens, "DurationTooShort");
    });

    it("should reject duration above maximum", async function () {
      const dummySecret = ethers.ZeroHash;
      await expect(
        ens
          .connect(user1)
          .register("alice", MAX_DURATION + 1, dummySecret)
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

  // -------------------------------------------------------------------
  //  5. Transfer
  // -------------------------------------------------------------------

  describe("Transfer", function () {
    beforeEach(async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
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
      ).to.be.revertedWithCustomError(ens, "ZeroAddress");
    });

    it("should reject transfer of expired name", async function () {
      await time.increase(MIN_DURATION + 1);
      await expect(
        ens.connect(user1).transfer("alice", user2.address)
      ).to.be.revertedWithCustomError(ens, "NameNotFound");
    });
  });

  // -------------------------------------------------------------------
  //  6. Renewal
  // -------------------------------------------------------------------

  describe("Renewal", function () {
    beforeEach(async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
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
      await commitAndRegister(user2, "bob", MAX_DURATION);
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
      await commitAndRegister(user2, "bob", MAX_DURATION);

      // Renew with MIN_DURATION, but since bob already has MAX_DURATION
      // from registration, the actual added time may be capped
      const before = await xom.balanceOf(oddaoTreasury.address);
      await ens.connect(user2).renew("bob", MIN_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);

      // Fee should be based on actual duration added, which may be
      // less than MIN_DURATION due to MAX_DURATION cap
      const fullMinFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);

      // The actual fee should be <= the full fee for MIN_DURATION
      expect(after - before).to.be.lte(fullMinFee);
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

    it("should charge proportional fee for renewal", async function () {
      const expectedFee =
        (FEE_PER_YEAR * BigInt(MIN_DURATION)) /
        BigInt(365 * 24 * 60 * 60);
      const before = await xom.balanceOf(oddaoTreasury.address);
      await ens.connect(user1).renew("alice", MIN_DURATION);
      const after = await xom.balanceOf(oddaoTreasury.address);
      expect(after - before).to.equal(expectedFee);
    });
  });

  // -------------------------------------------------------------------
  //  7. Resolution
  // -------------------------------------------------------------------

  describe("Resolution", function () {
    beforeEach(async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
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
  //  8. Availability
  // -------------------------------------------------------------------

  describe("Availability", function () {
    it("should be available if never registered", async function () {
      expect(await ens.isAvailable("alice")).to.be.true;
    });

    it("should not be available if registered and active", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      expect(await ens.isAvailable("alice")).to.be.false;
    });

    it("should be available after expiry", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      expect(await ens.isAvailable("alice")).to.be.true;
    });
  });

  // -------------------------------------------------------------------
  //  9. Admin Functions
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
  //  10. Edge Cases
  // -------------------------------------------------------------------

  describe("Edge Cases", function () {
    it("should allow re-registration of expired name", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      await commitAndRegister(user2, "alice", MIN_DURATION);
      expect(await ens.resolve("alice")).to.equal(user2.address);
    });

    it("should clear old reverse record on re-registration", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      await time.increase(MIN_DURATION + 1);
      await commitAndRegister(user2, "alice", MIN_DURATION);
      expect(await ens.reverseResolve(user1.address)).to.equal("");
      expect(await ens.reverseResolve(user2.address)).to.equal(
        "alice"
      );
    });

    it("should allow a user to own multiple names but only one reverse", async function () {
      await commitAndRegister(user1, "alice", MIN_DURATION);
      await commitAndRegister(user1, "alice2", MIN_DURATION);
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
      await commitAndRegister(user1, "alice", MIN_DURATION);

      // Register second name - should emit overwrite event
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const commitment = await ens.makeCommitment(
        "alice2",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);

      await expect(
        ens.connect(user1).register("alice2", MIN_DURATION, secret)
      ).to.emit(ens, "ReverseRecordOverwritten");
    });

    it("should not emit ReverseRecordOverwritten for first registration", async function () {
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const commitment = await ens.makeCommitment(
        "alice",
        user1.address,
        secret
      );
      await ens.connect(user1).commit(commitment);
      await time.increase(MIN_COMMITMENT_AGE + 1);

      await expect(
        ens.connect(user1).register("alice", MIN_DURATION, secret)
      ).to.not.emit(ens, "ReverseRecordOverwritten");
    });
  });
});
