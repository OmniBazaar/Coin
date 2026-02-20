const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniYieldFeeCollector Test Suite
 * @notice Tests for the performance-fee collector used by OmniBazaar yield aggregation.
 * @dev Validates constructor guards, fee calculation, collectFeeAndForward flow,
 *      cumulative tracking, rescueTokens access control, and event emissions.
 */
describe("OmniYieldFeeCollector", function () {
  let owner;
  let feeCollector;
  let user;
  let collector;
  let token;

  const PERFORMANCE_FEE_BPS = 500n; // 5%
  const BPS_DENOMINATOR = 10_000n;

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeCollector = signers[1];
    user = signers[2];
  });

  beforeEach(async function () {
    // Deploy a MockERC20 as the yield token (2-arg constructor: name, symbol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("Yield Token", "YLD");
    await token.waitForDeployment();

    // Mint supply to owner for distribution
    await token.mint(owner.address, ethers.parseEther("1000000"));

    // Deploy the fee collector
    const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
    collector = await Collector.deploy(feeCollector.address, PERFORMANCE_FEE_BPS);
    await collector.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should deploy with valid feeCollector and performanceFeeBps", async function () {
      expect(await collector.feeCollector()).to.equal(feeCollector.address);
      expect(await collector.performanceFeeBps()).to.equal(PERFORMANCE_FEE_BPS);
    });

    it("should revert when feeCollector is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(ethers.ZeroAddress, PERFORMANCE_FEE_BPS)
      ).to.be.revertedWithCustomError(Collector, "InvalidFeeCollector");
    });

    it("should revert when performanceFeeBps is zero", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(feeCollector.address, 0)
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });

    it("should revert when performanceFeeBps exceeds 1000", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(feeCollector.address, 1001)
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable getters
  // ---------------------------------------------------------------------------

  describe("Immutable getters", function () {
    it("should return the correct feeCollector", async function () {
      expect(await collector.feeCollector()).to.equal(feeCollector.address);
    });

    it("should return the correct performanceFeeBps", async function () {
      expect(await collector.performanceFeeBps()).to.equal(PERFORMANCE_FEE_BPS);
    });
  });

  // ---------------------------------------------------------------------------
  // calculateFee
  // ---------------------------------------------------------------------------

  describe("calculateFee", function () {
    it("should return the correct fee and net amounts", async function () {
      const yieldAmount = ethers.parseEther("1000");
      const expectedFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = yieldAmount - expectedFee;

      const [feeAmount, netAmount] = await collector.calculateFee(yieldAmount);

      expect(feeAmount).to.equal(expectedFee);
      expect(netAmount).to.equal(expectedNet);
    });

    it("should return zero fee and full amount when yield is small enough to round to zero", async function () {
      // With 500 bps (5%), a yield of 19 wei: fee = 19 * 500 / 10000 = 0
      const yieldAmount = 19n;
      const [feeAmount, netAmount] = await collector.calculateFee(yieldAmount);

      expect(feeAmount).to.equal(0n);
      expect(netAmount).to.equal(yieldAmount);
    });
  });

  // ---------------------------------------------------------------------------
  // collectFeeAndForward
  // ---------------------------------------------------------------------------

  describe("collectFeeAndForward", function () {
    const yieldAmount = ethers.parseEther("1000");

    beforeEach(async function () {
      // Give user some tokens and approve the collector
      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(
        await collector.getAddress(),
        yieldAmount
      );
    });

    it("should collect the fee and forward the net amount to the user", async function () {
      const expectedFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = yieldAmount - expectedFee;

      const userBalanceBefore = await token.balanceOf(user.address);
      const collectorBalanceBefore = await token.balanceOf(feeCollector.address);

      await collector.connect(user).collectFeeAndForward(
        await token.getAddress(),
        yieldAmount
      );

      // User ends up with: original - yieldAmount (pulled) + netAmount (forwarded back)
      expect(await token.balanceOf(user.address)).to.equal(
        userBalanceBefore - yieldAmount + expectedNet
      );
      // Fee collector receives the fee
      expect(await token.balanceOf(feeCollector.address)).to.equal(
        collectorBalanceBefore + expectedFee
      );
    });

    it("should emit FeeCollected event with correct parameters", async function () {
      const expectedFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = yieldAmount - expectedFee;

      await expect(
        collector.connect(user).collectFeeAndForward(
          await token.getAddress(),
          yieldAmount
        )
      )
        .to.emit(collector, "FeeCollected")
        .withArgs(
          user.address,
          await token.getAddress(),
          yieldAmount,
          expectedFee,
          expectedNet
        );
    });

    it("should revert with ZeroAmount when yieldAmount is 0", async function () {
      await expect(
        collector.connect(user).collectFeeAndForward(
          await token.getAddress(),
          0
        )
      ).to.be.revertedWithCustomError(collector, "ZeroAmount");
    });

    it("should revert with InvalidTokenAddress when token is zero address", async function () {
      await expect(
        collector.connect(user).collectFeeAndForward(
          ethers.ZeroAddress,
          yieldAmount
        )
      ).to.be.revertedWithCustomError(collector, "InvalidTokenAddress");
    });
  });

  // ---------------------------------------------------------------------------
  // totalFeesCollected
  // ---------------------------------------------------------------------------

  describe("totalFeesCollected", function () {
    it("should track cumulative fees across multiple collections", async function () {
      const yieldAmount = ethers.parseEther("500");
      const expectedFeePerCall = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      // Fund user and approve for two calls
      await token.transfer(user.address, yieldAmount * 2n);
      await token.connect(user).approve(collectorAddress, yieldAmount * 2n);

      // First collection
      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);
      expect(await collector.totalFeesCollected(tokenAddress)).to.equal(expectedFeePerCall);

      // Second collection
      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);
      expect(await collector.totalFeesCollected(tokenAddress)).to.equal(expectedFeePerCall * 2n);
    });

    it("should return zero for tokens that have never been collected", async function () {
      expect(await collector.totalFeesCollected(await token.getAddress())).to.equal(0);
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens
  // ---------------------------------------------------------------------------

  describe("rescueTokens", function () {
    it("should revert when called by non-feeCollector", async function () {
      await expect(
        collector.connect(user).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "InvalidFeeCollector");
    });

    it("should allow feeCollector to rescue tokens sent directly to the contract", async function () {
      const rescueAmount = ethers.parseEther("42");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      // Accidentally send tokens to the contract
      await token.transfer(collectorAddress, rescueAmount);
      expect(await token.balanceOf(collectorAddress)).to.equal(rescueAmount);

      const balanceBefore = await token.balanceOf(feeCollector.address);

      await collector.connect(feeCollector).rescueTokens(tokenAddress);

      expect(await token.balanceOf(collectorAddress)).to.equal(0);
      expect(await token.balanceOf(feeCollector.address)).to.equal(
        balanceBefore + rescueAmount
      );
    });
  });
});
