const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniPredictionRouter Test Suite
 * @notice Tests for the trustless fee-collecting prediction market router.
 * @dev Validates constructor guards, immutable getters, platform allowlist
 *      management, buyWithFee input validation (including deadline and
 *      platform approval), rescueTokens access control, and event emissions.
 */
describe("OmniPredictionRouter", function () {
  let owner;
  let feeCollector;
  let user;
  let platformTarget;
  let attacker;
  let router;
  let collateral;

  const MAX_FEE_BPS = 200n; // 2%
  const TOTAL_AMOUNT = ethers.parseEther("100");

  /** @notice Returns a deadline 1 hour in the future */
  async function futureDeadline() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp + 3600;
  }

  /** @notice Returns a deadline that has already passed */
  async function pastDeadline() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp - 1;
  }

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeCollector = signers[1];
    user = signers[2];
    platformTarget = signers[3];
    attacker = signers[4];
  });

  beforeEach(async function () {
    // Deploy a MockERC20 as collateral token (2-arg constructor: name, symbol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    collateral = await MockERC20.deploy("USD Coin", "USDC");
    await collateral.waitForDeployment();

    // Mint supply to owner for distribution
    await collateral.mint(owner.address, ethers.parseEther("1000000"));

    // Deploy the router with valid parameters
    const Router = await ethers.getContractFactory("OmniPredictionRouter");
    router = await Router.deploy(feeCollector.address, MAX_FEE_BPS);
    await router.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should deploy with valid feeCollector and maxFeeBps", async function () {
      expect(await router.FEE_COLLECTOR()).to.equal(feeCollector.address);
      expect(await router.MAX_FEE_BPS()).to.equal(MAX_FEE_BPS);
    });

    it("should revert when feeCollector is the zero address", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(ethers.ZeroAddress, MAX_FEE_BPS)
      ).to.be.revertedWithCustomError(Router, "InvalidFeeCollector");
    });

    it("should revert when maxFeeBps is zero", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(feeCollector.address, 0)
      ).to.be.revertedWithCustomError(Router, "FeeExceedsCap");
    });

    it("should revert when maxFeeBps exceeds 1000", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(feeCollector.address, 1001)
      ).to.be.revertedWithCustomError(Router, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable getters
  // ---------------------------------------------------------------------------

  describe("Immutable getters", function () {
    it("should return the correct feeCollector", async function () {
      expect(await router.FEE_COLLECTOR()).to.equal(feeCollector.address);
    });

    it("should return the correct MAX_FEE_BPS", async function () {
      expect(await router.MAX_FEE_BPS()).to.equal(MAX_FEE_BPS);
    });
  });

  // ---------------------------------------------------------------------------
  // setPlatformApproval
  // ---------------------------------------------------------------------------

  describe("setPlatformApproval", function () {
    it("should allow feeCollector to approve a platform", async function () {
      await router.connect(feeCollector).setPlatformApproval(
        platformTarget.address, true
      );
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(true);
    });

    it("should allow feeCollector to revoke a platform", async function () {
      await router.connect(feeCollector).setPlatformApproval(
        platformTarget.address, true
      );
      await router.connect(feeCollector).setPlatformApproval(
        platformTarget.address, false
      );
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(false);
    });

    it("should emit PlatformApprovalChanged on approval", async function () {
      await expect(
        router.connect(feeCollector).setPlatformApproval(
          platformTarget.address, true
        )
      ).to.emit(router, "PlatformApprovalChanged")
        .withArgs(platformTarget.address, true);
    });

    it("should emit PlatformApprovalChanged on revocation", async function () {
      await router.connect(feeCollector).setPlatformApproval(
        platformTarget.address, true
      );
      await expect(
        router.connect(feeCollector).setPlatformApproval(
          platformTarget.address, false
        )
      ).to.emit(router, "PlatformApprovalChanged")
        .withArgs(platformTarget.address, false);
    });

    it("should revert when called by non-feeCollector", async function () {
      await expect(
        router.connect(user).setPlatformApproval(
          platformTarget.address, true
        )
      ).to.be.revertedWithCustomError(router, "InvalidFeeCollector");
    });

    it("should revert when called by attacker", async function () {
      await expect(
        router.connect(attacker).setPlatformApproval(
          platformTarget.address, true
        )
      ).to.be.revertedWithCustomError(router, "InvalidFeeCollector");
    });

    it("should revert when platform is the zero address", async function () {
      await expect(
        router.connect(feeCollector).setPlatformApproval(
          ethers.ZeroAddress, true
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFee
  // ---------------------------------------------------------------------------

  describe("buyWithFee", function () {
    it("should revert with DeadlineExpired when deadline has passed", async function () {
      const deadline = await pastDeadline();
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "DeadlineExpired");
    });

    it("should revert with ZeroAmount when totalAmount is 0", async function () {
      const deadline = await futureDeadline();
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          0,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "ZeroAmount");
    });

    it("should revert with InvalidCollateralToken when collateral is zero address", async function () {
      const deadline = await futureDeadline();
      await expect(
        router.connect(user).buyWithFee(
          ethers.ZeroAddress,
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidCollateralToken");
    });

    it("should revert with InvalidPlatformTarget when platform is zero address", async function () {
      const deadline = await futureDeadline();
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          ethers.ZeroAddress,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with InvalidPlatformTarget when platform is not approved", async function () {
      const deadline = await futureDeadline();
      // platformTarget is NOT approved
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with InvalidPlatformTarget when platform is the collateral token", async function () {
      const deadline = await futureDeadline();
      const collateralAddress = await collateral.getAddress();
      // Approve the collateral address as a platform (admin mistake)
      await router.connect(feeCollector).setPlatformApproval(
        collateralAddress, true
      );
      await expect(
        router.connect(user).buyWithFee(
          collateralAddress,
          TOTAL_AMOUNT,
          0,
          collateralAddress,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with InvalidPlatformTarget when platform is the router itself", async function () {
      const deadline = await futureDeadline();
      const routerAddress = await router.getAddress();
      // Approve the router address as a platform (admin mistake)
      await router.connect(feeCollector).setPlatformApproval(
        routerAddress, true
      );
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          routerAddress,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with FeeExceedsTotal when feeAmount > totalAmount", async function () {
      const deadline = await futureDeadline();
      const feeAmount = TOTAL_AMOUNT + 1n;
      // Use a deployed contract as the platform target (must have code after C-01)
      // Deploy a dummy contract to act as an approved platform
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const dummyPlatform = await MockERC20.deploy("Platform", "PLT");
      const platformAddr = await dummyPlatform.getAddress();
      // Approve the platform so we reach the fee check
      await router.connect(feeCollector).setPlatformApproval(platformAddr, true);
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          feeAmount,
          platformAddr,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsTotal");
    });

    it("should revert with FeeExceedsCap when fee exceeds maxFeeBps cap", async function () {
      const deadline = await futureDeadline();
      // maxFeeBps = 200 (2%), so max fee on 100 ETH = 2 ETH
      // Provide a fee of 3 ETH which exceeds the 2% cap
      const feeAmount = ethers.parseEther("3");
      // Use a deployed contract as the platform target (must have code after C-01)
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const dummyPlatform = await MockERC20.deploy("Platform", "PLT");
      const platformAddr = await dummyPlatform.getAddress();
      // Approve the platform so we reach the fee cap check
      await router.connect(feeCollector).setPlatformApproval(platformAddr, true);
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          feeAmount,
          platformAddr,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsCap");
    });

    it("should revert with InvalidPlatformTarget after platform is revoked", async function () {
      const deadline = await futureDeadline();
      // Approve then revoke
      await router.connect(feeCollector).setPlatformApproval(
        platformTarget.address, true
      );
      await router.connect(feeCollector).setPlatformApproval(
        platformTarget.address, false
      );
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens
  // ---------------------------------------------------------------------------

  describe("rescueTokens", function () {
    it("should revert when called by non-feeCollector", async function () {
      await expect(
        router.connect(user).rescueTokens(await collateral.getAddress())
      ).to.be.revertedWithCustomError(router, "InvalidFeeCollector");
    });

    it("should allow feeCollector to rescue tokens", async function () {
      const collateralAddress = await collateral.getAddress();
      const routerAddress = await router.getAddress();

      // Send some tokens directly to the router (simulating accidental transfer)
      const rescueAmount = ethers.parseEther("50");
      await collateral.transfer(routerAddress, rescueAmount);

      // Verify tokens are on the router
      expect(await collateral.balanceOf(routerAddress)).to.equal(rescueAmount);

      const balanceBefore = await collateral.balanceOf(feeCollector.address);

      // feeCollector rescues the tokens
      await router.connect(feeCollector).rescueTokens(collateralAddress);

      expect(await collateral.balanceOf(routerAddress)).to.equal(0);
      expect(await collateral.balanceOf(feeCollector.address)).to.equal(
        balanceBefore + rescueAmount
      );
    });
  });
});
