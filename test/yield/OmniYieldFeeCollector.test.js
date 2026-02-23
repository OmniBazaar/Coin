const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniYieldFeeCollector Test Suite
 * @notice Tests for the performance-fee collector used by OmniBazaar yield aggregation.
 * @dev After the M-01/M-02 audit fix, the constructor takes four arguments
 *      (primaryRecipient, stakingPool, validatorRecipient, performanceFeeBps)
 *      and fees are split 70/20/10. Validates constructor guards, fee
 *      calculation, collectFeeAndForward 70/20/10 split, cumulative
 *      tracking, rescueTokens access control, and event emissions.
 */
describe("OmniYieldFeeCollector", function () {
  let owner;
  let primaryRecipient;
  let stakingPool;
  let validatorRecipient;
  let user;
  let collector;
  let token;

  const PERFORMANCE_FEE_BPS = 500n; // 5%
  const BPS_DENOMINATOR = 10_000n;

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    primaryRecipient = signers[1];
    stakingPool = signers[2];
    validatorRecipient = signers[3];
    user = signers[4];
  });

  beforeEach(async function () {
    // Deploy a MockERC20 as the yield token (2-arg constructor: name, symbol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("Yield Token", "YLD");
    await token.waitForDeployment();

    // Mint supply to owner for distribution
    await token.mint(owner.address, ethers.parseEther("1000000"));

    // Deploy the fee collector with 70/20/10 split recipients
    const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
    collector = await Collector.deploy(
      primaryRecipient.address,
      stakingPool.address,
      validatorRecipient.address,
      PERFORMANCE_FEE_BPS
    );
    await collector.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should deploy with valid recipients and performanceFeeBps", async function () {
      expect(await collector.primaryRecipient()).to.equal(primaryRecipient.address);
      expect(await collector.stakingPool()).to.equal(stakingPool.address);
      expect(await collector.validatorRecipient()).to.equal(validatorRecipient.address);
      expect(await collector.performanceFeeBps()).to.equal(PERFORMANCE_FEE_BPS);
    });

    it("should revert when primaryRecipient is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          ethers.ZeroAddress,
          stakingPool.address,
          validatorRecipient.address,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });

    it("should revert when stakingPool is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          primaryRecipient.address,
          ethers.ZeroAddress,
          validatorRecipient.address,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });

    it("should revert when validatorRecipient is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          primaryRecipient.address,
          stakingPool.address,
          ethers.ZeroAddress,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });

    it("should revert when performanceFeeBps is zero", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          primaryRecipient.address,
          stakingPool.address,
          validatorRecipient.address,
          0
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });

    it("should revert when performanceFeeBps exceeds 1000", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          primaryRecipient.address,
          stakingPool.address,
          validatorRecipient.address,
          1001
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable getters
  // ---------------------------------------------------------------------------

  describe("Immutable getters", function () {
    it("should return the correct primaryRecipient", async function () {
      expect(await collector.primaryRecipient()).to.equal(primaryRecipient.address);
    });

    it("should return the correct stakingPool", async function () {
      expect(await collector.stakingPool()).to.equal(stakingPool.address);
    });

    it("should return the correct validatorRecipient", async function () {
      expect(await collector.validatorRecipient()).to.equal(validatorRecipient.address);
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

    it("should collect the fee and distribute 70/20/10 to recipients", async function () {
      const expectedFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = yieldAmount - expectedFee;

      // 70/20/10 split of the fee
      const primaryShare = (expectedFee * 70n) / 100n;
      const stakingShare = (expectedFee * 20n) / 100n;
      const validatorShare = expectedFee - primaryShare - stakingShare;

      const userBalBefore = await token.balanceOf(user.address);
      const primaryBalBefore = await token.balanceOf(primaryRecipient.address);
      const stakingBalBefore = await token.balanceOf(stakingPool.address);
      const validatorBalBefore = await token.balanceOf(validatorRecipient.address);

      await collector.connect(user).collectFeeAndForward(
        await token.getAddress(),
        yieldAmount
      );

      // User ends up with: original - yieldAmount (pulled) + netAmount (forwarded back)
      expect(await token.balanceOf(user.address)).to.equal(
        userBalBefore - yieldAmount + expectedNet
      );
      // Primary recipient gets 70% of the fee
      expect(await token.balanceOf(primaryRecipient.address)).to.equal(
        primaryBalBefore + primaryShare
      );
      // Staking pool gets 20% of the fee
      expect(await token.balanceOf(stakingPool.address)).to.equal(
        stakingBalBefore + stakingShare
      );
      // Validator gets 10% of the fee
      expect(await token.balanceOf(validatorRecipient.address)).to.equal(
        validatorBalBefore + validatorShare
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
    it("should revert when called by non-primaryRecipient", async function () {
      await expect(
        collector.connect(user).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotPrimaryRecipient");
    });

    it("should allow primaryRecipient to rescue tokens sent directly to the contract", async function () {
      const rescueAmount = ethers.parseEther("42");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      // Accidentally send tokens to the contract
      await token.transfer(collectorAddress, rescueAmount);
      expect(await token.balanceOf(collectorAddress)).to.equal(rescueAmount);

      const balanceBefore = await token.balanceOf(primaryRecipient.address);

      await collector.connect(primaryRecipient).rescueTokens(tokenAddress);

      expect(await token.balanceOf(collectorAddress)).to.equal(0);
      expect(await token.balanceOf(primaryRecipient.address)).to.equal(
        balanceBefore + rescueAmount
      );
    });
  });
});
