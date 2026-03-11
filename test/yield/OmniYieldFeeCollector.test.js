const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniYieldFeeCollector Test Suite
 * @notice Tests for the performance-fee collector used by OmniBazaar yield aggregation.
 * @dev The constructor takes four arguments
 *      (oddaoTreasury, stakingPool, protocolTreasury, performanceFeeBps)
 *      and fees are split 70/20/10 (ODDAO/StakingPool/Protocol).
 *      Validates constructor guards, fee calculation,
 *      collectFeeAndForward 70/20/10 split, cumulative tracking,
 *      rescueTokens access control, and event emissions.
 */
describe("OmniYieldFeeCollector", function () {
  let owner;
  let oddaoTreasury;
  let stakingPool;
  let protocolTreasury;
  let user;
  let collector;
  let token;

  const PERFORMANCE_FEE_BPS = 500n; // 5%
  const BPS_DENOMINATOR = 10_000n;

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    oddaoTreasury = signers[1];
    stakingPool = signers[2];
    protocolTreasury = signers[3];
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
      oddaoTreasury.address,
      stakingPool.address,
      protocolTreasury.address,
      PERFORMANCE_FEE_BPS
    );
    await collector.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should deploy with valid recipients and performanceFeeBps", async function () {
      expect(await collector.oddaoTreasury()).to.equal(oddaoTreasury.address);
      expect(await collector.stakingPool()).to.equal(stakingPool.address);
      expect(await collector.protocolTreasury()).to.equal(protocolTreasury.address);
      expect(await collector.performanceFeeBps()).to.equal(PERFORMANCE_FEE_BPS);
    });

    it("should revert when oddaoTreasury is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          ethers.ZeroAddress,
          stakingPool.address,
          protocolTreasury.address,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });

    it("should revert when stakingPool is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          oddaoTreasury.address,
          ethers.ZeroAddress,
          protocolTreasury.address,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });

    it("should revert when protocolTreasury is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          oddaoTreasury.address,
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
          oddaoTreasury.address,
          stakingPool.address,
          protocolTreasury.address,
          0
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });

    it("should revert when performanceFeeBps exceeds 1000", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          oddaoTreasury.address,
          stakingPool.address,
          protocolTreasury.address,
          1001
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable getters
  // ---------------------------------------------------------------------------

  describe("Immutable getters", function () {
    it("should return the correct oddaoTreasury", async function () {
      expect(await collector.oddaoTreasury()).to.equal(oddaoTreasury.address);
    });

    it("should return the correct stakingPool", async function () {
      expect(await collector.stakingPool()).to.equal(stakingPool.address);
    });

    it("should return the correct protocolTreasury", async function () {
      expect(await collector.protocolTreasury()).to.equal(protocolTreasury.address);
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
      const oddaoShare = (expectedFee * 70n) / 100n;
      const stakingShare = (expectedFee * 20n) / 100n;
      const protocolShare = expectedFee - oddaoShare - stakingShare;

      const userBalBefore = await token.balanceOf(user.address);
      const oddaoBalBefore = await token.balanceOf(oddaoTreasury.address);
      const stakingBalBefore = await token.balanceOf(stakingPool.address);
      const protocolBalBefore = await token.balanceOf(protocolTreasury.address);

      await collector.connect(user).collectFeeAndForward(
        await token.getAddress(),
        yieldAmount
      );

      // User ends up with: original - yieldAmount (pulled) + netAmount (forwarded back)
      expect(await token.balanceOf(user.address)).to.equal(
        userBalBefore - yieldAmount + expectedNet
      );
      // ODDAO treasury gets 70% of the fee
      expect(await token.balanceOf(oddaoTreasury.address)).to.equal(
        oddaoBalBefore + oddaoShare
      );
      // Staking pool gets 20% of the fee
      expect(await token.balanceOf(stakingPool.address)).to.equal(
        stakingBalBefore + stakingShare
      );
      // Protocol treasury gets 10% of the fee (remainder for rounding dust)
      expect(await token.balanceOf(protocolTreasury.address)).to.equal(
        protocolBalBefore + protocolShare
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
    it("should revert when called by non-oddaoTreasury", async function () {
      await expect(
        collector.connect(user).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotOddaoTreasury");
    });

    it("should allow oddaoTreasury to rescue tokens sent directly to the contract", async function () {
      const rescueAmount = ethers.parseEther("42");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      // Accidentally send tokens to the contract
      await token.transfer(collectorAddress, rescueAmount);
      expect(await token.balanceOf(collectorAddress)).to.equal(rescueAmount);

      const balanceBefore = await token.balanceOf(oddaoTreasury.address);

      await collector.connect(oddaoTreasury).rescueTokens(tokenAddress);

      expect(await token.balanceOf(collectorAddress)).to.equal(0);
      expect(await token.balanceOf(oddaoTreasury.address)).to.equal(
        balanceBefore + rescueAmount
      );
    });
  });

  // ===========================================================================
  // NEW TESTS BELOW
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Constructor boundary values
  // ---------------------------------------------------------------------------

  describe("Constructor boundary values", function () {
    it("should deploy with performanceFeeBps = 1 (minimum)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        oddaoTreasury.address,
        stakingPool.address,
        protocolTreasury.address,
        1
      );
      await c.waitForDeployment();
      expect(await c.performanceFeeBps()).to.equal(1n);
    });

    it("should deploy with performanceFeeBps = 1000 (maximum)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        oddaoTreasury.address,
        stakingPool.address,
        protocolTreasury.address,
        1000
      );
      await c.waitForDeployment();
      expect(await c.performanceFeeBps()).to.equal(1000n);
    });

    it("should revert when performanceFeeBps is 1001", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          oddaoTreasury.address,
          stakingPool.address,
          protocolTreasury.address,
          1001
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });

    it("should revert when all three recipients are the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          ethers.ZeroAddress,
          ethers.ZeroAddress,
          ethers.ZeroAddress,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-token fee collection
  // ---------------------------------------------------------------------------

  describe("Multi-token fee collection", function () {
    let tokenB;

    beforeEach(async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      tokenB = await MockERC20.deploy("Yield Token B", "YLDB");
      await tokenB.waitForDeployment();
      await tokenB.mint(owner.address, ethers.parseEther("1000000"));
    });

    it("should track fees independently per token", async function () {
      const yieldA = ethers.parseEther("1000");
      const yieldB = ethers.parseEther("2000");
      const collectorAddress = await collector.getAddress();
      const tokenAAddress = await token.getAddress();
      const tokenBAddress = await tokenB.getAddress();

      // Fund user with both tokens
      await token.transfer(user.address, yieldA);
      await tokenB.transfer(user.address, yieldB);
      await token.connect(user).approve(collectorAddress, yieldA);
      await tokenB.connect(user).approve(collectorAddress, yieldB);

      // Collect from token A
      await collector.connect(user).collectFeeAndForward(tokenAAddress, yieldA);
      const expectedFeeA = (yieldA * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;

      // Collect from token B
      await collector.connect(user).collectFeeAndForward(tokenBAddress, yieldB);
      const expectedFeeB = (yieldB * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;

      expect(await collector.totalFeesCollected(tokenAAddress)).to.equal(expectedFeeA);
      expect(await collector.totalFeesCollected(tokenBAddress)).to.equal(expectedFeeB);
      // They should be different amounts
      expect(expectedFeeA).to.not.equal(expectedFeeB);
    });

    it("should distribute fees correctly for a second token", async function () {
      const yieldB = ethers.parseEther("5000");
      const collectorAddress = await collector.getAddress();
      const tokenBAddress = await tokenB.getAddress();

      await tokenB.transfer(user.address, yieldB);
      await tokenB.connect(user).approve(collectorAddress, yieldB);

      const oddaoBalBefore = await tokenB.balanceOf(oddaoTreasury.address);
      const stakingBalBefore = await tokenB.balanceOf(stakingPool.address);
      const protocolBalBefore = await tokenB.balanceOf(protocolTreasury.address);

      await collector.connect(user).collectFeeAndForward(tokenBAddress, yieldB);

      const expectedFee = (yieldB * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const oddaoShare = (expectedFee * 7000n) / 10000n;
      const stakingShare = (expectedFee * 2000n) / 10000n;
      const protocolShare = expectedFee - oddaoShare - stakingShare;

      expect(await tokenB.balanceOf(oddaoTreasury.address)).to.equal(
        oddaoBalBefore + oddaoShare
      );
      expect(await tokenB.balanceOf(stakingPool.address)).to.equal(
        stakingBalBefore + stakingShare
      );
      expect(await tokenB.balanceOf(protocolTreasury.address)).to.equal(
        protocolBalBefore + protocolShare
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Fee distribution precision
  // ---------------------------------------------------------------------------

  describe("Fee distribution precision", function () {
    it("should ensure fee shares sum to exactly the total fee (no dust lost)", async function () {
      // Use an amount that can cause rounding: 333 wei at 5% => fee = 16
      const yieldAmount = 333n;
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      const oddaoBefore = await token.balanceOf(oddaoTreasury.address);
      const stakingBefore = await token.balanceOf(stakingPool.address);
      const protocolBefore = await token.balanceOf(protocolTreasury.address);
      const userBefore = await token.balanceOf(user.address);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      const oddaoAfter = await token.balanceOf(oddaoTreasury.address);
      const stakingAfter = await token.balanceOf(stakingPool.address);
      const protocolAfter = await token.balanceOf(protocolTreasury.address);
      const userAfter = await token.balanceOf(user.address);

      const oddaoDelta = oddaoAfter - oddaoBefore;
      const stakingDelta = stakingAfter - stakingBefore;
      const protocolDelta = protocolAfter - protocolBefore;
      const userDelta = userBefore - userAfter; // User spent this amount in net

      // Total fee = sum of all recipient deltas
      const totalFee = oddaoDelta + stakingDelta + protocolDelta;
      // User should have received yieldAmount - totalFee back
      expect(userDelta).to.equal(totalFee);
      // All tokens accounted for: user net loss + user net received = yieldAmount
      const userNetReceived = yieldAmount - userDelta;
      expect(totalFee + userNetReceived).to.equal(yieldAmount);
    });

    it("should handle 1 wei yield amount (fee rounds to zero, user gets all)", async function () {
      const yieldAmount = 1n;
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      const userBefore = await token.balanceOf(user.address);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      // Fee = 1 * 500 / 10000 = 0, so user gets everything back
      const userAfter = await token.balanceOf(user.address);
      expect(userAfter).to.equal(userBefore);
      expect(await collector.totalFeesCollected(tokenAddress)).to.equal(0n);
    });

    it("should handle minimum amount that produces a non-zero fee (20 wei at 5%)", async function () {
      // 20 * 500 / 10000 = 1 wei fee
      const yieldAmount = 20n;
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      expect(await collector.totalFeesCollected(tokenAddress)).to.equal(1n);
    });

    it("should correctly split a 1 wei fee (protocol gets remainder)", async function () {
      // With a 1 wei total fee:
      //   oddao   = 1 * 7000 / 10000 = 0
      //   staking = 1 * 2000 / 10000 = 0
      //   protocol = 1 - 0 - 0 = 1 (remainder)
      const yieldAmount = 20n; // produces 1 wei fee
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      const protocolBefore = await token.balanceOf(protocolTreasury.address);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      // Protocol treasury gets the 1 wei as remainder
      const protocolAfter = await token.balanceOf(protocolTreasury.address);
      expect(protocolAfter - protocolBefore).to.equal(1n);
    });
  });

  // ---------------------------------------------------------------------------
  // calculateFee edge cases
  // ---------------------------------------------------------------------------

  describe("calculateFee edge cases", function () {
    it("should return zero fee for zero yield", async function () {
      const [feeAmount, netAmount] = await collector.calculateFee(0n);
      expect(feeAmount).to.equal(0n);
      expect(netAmount).to.equal(0n);
    });

    it("should return correct values for a large yield amount", async function () {
      const largeYield = ethers.parseEther("1000000"); // 1M tokens
      const expectedFee = (largeYield * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = largeYield - expectedFee;

      const [feeAmount, netAmount] = await collector.calculateFee(largeYield);
      expect(feeAmount).to.equal(expectedFee);
      expect(netAmount).to.equal(expectedNet);
    });

    it("should satisfy feeAmount + netAmount == yieldAmount for any input", async function () {
      const amounts = [1n, 19n, 20n, 100n, 999n, ethers.parseEther("1"), ethers.parseEther("999999")];
      for (const amount of amounts) {
        const [fee, net] = await collector.calculateFee(amount);
        expect(fee + net).to.equal(amount);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // collectFeeAndForward - additional scenarios
  // ---------------------------------------------------------------------------

  describe("collectFeeAndForward - additional scenarios", function () {
    it("should revert when user has insufficient allowance", async function () {
      const yieldAmount = ethers.parseEther("1000");
      await token.transfer(user.address, yieldAmount);
      // Approve less than the yield amount
      await token.connect(user).approve(
        await collector.getAddress(),
        yieldAmount / 2n
      );

      await expect(
        collector.connect(user).collectFeeAndForward(
          await token.getAddress(),
          yieldAmount
        )
      ).to.be.reverted;
    });

    it("should revert when user has insufficient balance", async function () {
      const yieldAmount = ethers.parseEther("1000");
      // User has no tokens, but approves
      await token.connect(user).approve(
        await collector.getAddress(),
        yieldAmount
      );

      await expect(
        collector.connect(user).collectFeeAndForward(
          await token.getAddress(),
          yieldAmount
        )
      ).to.be.reverted;
    });

    it("should leave zero contract balance after collection", async function () {
      const yieldAmount = ethers.parseEther("1000");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      expect(await token.balanceOf(collectorAddress)).to.equal(0n);
    });

    it("should work when called by different users sequentially", async function () {
      const signers = await ethers.getSigners();
      const user2 = signers[5];
      const yieldAmount = ethers.parseEther("500");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      // Fund both users
      await token.transfer(user.address, yieldAmount);
      await token.transfer(user2.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);
      await token.connect(user2).approve(collectorAddress, yieldAmount);

      // First user collects
      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);
      const feeAfterFirst = await collector.totalFeesCollected(tokenAddress);

      // Second user collects
      await collector.connect(user2).collectFeeAndForward(tokenAddress, yieldAmount);
      const feeAfterSecond = await collector.totalFeesCollected(tokenAddress);

      expect(feeAfterSecond).to.equal(feeAfterFirst * 2n);
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens - additional scenarios
  // ---------------------------------------------------------------------------

  describe("rescueTokens - additional scenarios", function () {
    it("should revert when called by stakingPool", async function () {
      await expect(
        collector.connect(stakingPool).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotOddaoTreasury");
    });

    it("should revert when called by protocolTreasury", async function () {
      await expect(
        collector.connect(protocolTreasury).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotOddaoTreasury");
    });

    it("should revert when called by contract deployer (owner)", async function () {
      await expect(
        collector.connect(owner).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotOddaoTreasury");
    });

    it("should emit TokensRescued event with correct parameters", async function () {
      const rescueAmount = ethers.parseEther("100");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(collectorAddress, rescueAmount);

      await expect(
        collector.connect(oddaoTreasury).rescueTokens(tokenAddress)
      )
        .to.emit(collector, "TokensRescued")
        .withArgs(tokenAddress, rescueAmount);
    });

    it("should not emit TokensRescued when contract has zero balance of the token", async function () {
      const tokenAddress = await token.getAddress();

      // No tokens to rescue, so no event should be emitted
      await expect(
        collector.connect(oddaoTreasury).rescueTokens(tokenAddress)
      ).to.not.emit(collector, "TokensRescued");
    });

    it("should rescue a different token (not the yield token)", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const otherToken = await MockERC20.deploy("Other Token", "OTH");
      await otherToken.waitForDeployment();
      await otherToken.mint(owner.address, ethers.parseEther("1000"));

      const rescueAmount = ethers.parseEther("77");
      const collectorAddress = await collector.getAddress();
      const otherAddress = await otherToken.getAddress();

      await otherToken.transfer(collectorAddress, rescueAmount);

      const balBefore = await otherToken.balanceOf(oddaoTreasury.address);
      await collector.connect(oddaoTreasury).rescueTokens(otherAddress);
      const balAfter = await otherToken.balanceOf(oddaoTreasury.address);

      expect(balAfter - balBefore).to.equal(rescueAmount);
    });
  });

  // ---------------------------------------------------------------------------
  // Different fee BPS configurations
  // ---------------------------------------------------------------------------

  describe("Different fee BPS configurations", function () {
    it("should collect correct fee at 1 bps (0.01%)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        oddaoTreasury.address,
        stakingPool.address,
        protocolTreasury.address,
        1 // 0.01%
      );
      await c.waitForDeployment();

      const yieldAmount = ethers.parseEther("10000");
      const collectorAddress = await c.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      await c.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      // Fee = 10000 * 1 / 10000 = 1 ether (in token terms)
      const expectedFee = (yieldAmount * 1n) / BPS_DENOMINATOR;
      expect(await c.totalFeesCollected(tokenAddress)).to.equal(expectedFee);
    });

    it("should collect correct fee at 1000 bps (10%)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        oddaoTreasury.address,
        stakingPool.address,
        protocolTreasury.address,
        1000 // 10%
      );
      await c.waitForDeployment();

      const yieldAmount = ethers.parseEther("1000");
      const collectorAddress = await c.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      await c.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      // Fee = 1000 * 1000 / 10000 = 100 ether
      const expectedFee = (yieldAmount * 1000n) / BPS_DENOMINATOR;
      expect(await c.totalFeesCollected(tokenAddress)).to.equal(expectedFee);
    });
  });

  // ---------------------------------------------------------------------------
  // Event emission edge cases
  // ---------------------------------------------------------------------------

  describe("Event emission edge cases", function () {
    it("should emit FeeCollected with zero fee when yield is too small", async function () {
      // 1 wei at 5% fee => fee = 0
      const yieldAmount = 1n;
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      await expect(
        collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount)
      )
        .to.emit(collector, "FeeCollected")
        .withArgs(user.address, tokenAddress, yieldAmount, 0n, yieldAmount);
    });

    it("should emit FeeCollected event for each collection call", async function () {
      const yieldAmount = ethers.parseEther("100");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount * 2n);
      await token.connect(user).approve(collectorAddress, yieldAmount * 2n);

      const expectedFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = yieldAmount - expectedFee;

      // First call
      await expect(
        collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount)
      )
        .to.emit(collector, "FeeCollected")
        .withArgs(user.address, tokenAddress, yieldAmount, expectedFee, expectedNet);

      // Second call - same event
      await expect(
        collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount)
      )
        .to.emit(collector, "FeeCollected")
        .withArgs(user.address, tokenAddress, yieldAmount, expectedFee, expectedNet);
    });
  });
});
