const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniPredictionRouter Test Suite
 * @notice Tests for the trustless fee-collecting prediction market router.
 * @dev Validates constructor guards, immutable getters, buyWithFee input
 *      validation, rescueTokens access control, and event emissions.
 */
describe("OmniPredictionRouter", function () {
  let owner;
  let feeCollector;
  let user;
  let platformTarget;
  let router;
  let collateral;

  const MAX_FEE_BPS = 200n; // 2%
  const TOTAL_AMOUNT = ethers.parseEther("100");

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeCollector = signers[1];
    user = signers[2];
    platformTarget = signers[3];
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
      expect(await router.feeCollector()).to.equal(feeCollector.address);
      expect(await router.maxFeeBps()).to.equal(MAX_FEE_BPS);
    });

    it("should revert when feeCollector is the zero address", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(ethers.ZeroAddress, MAX_FEE_BPS)
      ).to.be.revertedWithCustomError(Router, "InvalidCollateralToken");
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
      expect(await router.feeCollector()).to.equal(feeCollector.address);
    });

    it("should return the correct maxFeeBps", async function () {
      expect(await router.maxFeeBps()).to.equal(MAX_FEE_BPS);
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFee
  // ---------------------------------------------------------------------------

  describe("buyWithFee", function () {
    it("should revert with ZeroAmount when totalAmount is 0", async function () {
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          0,
          0,
          platformTarget.address,
          "0x"
        )
      ).to.be.revertedWithCustomError(router, "ZeroAmount");
    });

    it("should revert with InvalidCollateralToken when collateral is zero address", async function () {
      await expect(
        router.connect(user).buyWithFee(
          ethers.ZeroAddress,
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x"
        )
      ).to.be.revertedWithCustomError(router, "InvalidCollateralToken");
    });

    it("should revert with InvalidPlatformTarget when platform is zero address", async function () {
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          ethers.ZeroAddress,
          "0x"
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with FeeExceedsTotal when feeAmount > totalAmount", async function () {
      const feeAmount = TOTAL_AMOUNT + 1n;
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          feeAmount,
          platformTarget.address,
          "0x"
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsTotal");
    });

    it("should revert with FeeExceedsCap when fee exceeds maxFeeBps cap", async function () {
      // maxFeeBps = 200 (2%), so max fee on 100 ETH = 2 ETH
      // Provide a fee of 3 ETH which exceeds the 2% cap
      const feeAmount = ethers.parseEther("3");
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          feeAmount,
          platformTarget.address,
          "0x"
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens
  // ---------------------------------------------------------------------------

  describe("rescueTokens", function () {
    it("should revert when called by non-feeCollector", async function () {
      await expect(
        router.connect(user).rescueTokens(await collateral.getAddress())
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
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
