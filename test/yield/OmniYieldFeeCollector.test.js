const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniYieldFeeCollector Test Suite
 * @notice Tests for the performance-fee collector used by OmniBazaar yield aggregation.
 * @dev The constructor takes two arguments (feeVault, performanceFeeBps).
 *      All collected fees are forwarded in full to the UnifiedFeeVault,
 *      which handles the 70/20/10 split internally.
 *      Validates constructor guards, fee calculation,
 *      collectFeeAndForward forwarding to vault, cumulative tracking,
 *      rescueTokens access control, and event emissions.
 */
describe("OmniYieldFeeCollector", function () {
  let owner;
  let feeVault;
  let user;
  let collector;
  let token;

  const PERFORMANCE_FEE_BPS = 500n; // 5%
  const BPS_DENOMINATOR = 10_000n;

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeVault = signers[1];
    user = signers[4];
  });

  beforeEach(async function () {
    // Deploy a MockERC20 as the yield token (2-arg constructor: name, symbol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("Yield Token", "YLD");
    await token.waitForDeployment();

    // Mint supply to owner for distribution
    await token.mint(owner.address, ethers.parseEther("1000000"));

    // Deploy the fee collector with feeVault recipient
    const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
    collector = await Collector.deploy(
      feeVault.address,
      PERFORMANCE_FEE_BPS
    );
    await collector.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should deploy with valid feeVault and performanceFeeBps", async function () {
      expect(await collector.feeVault()).to.equal(feeVault.address);
      expect(await collector.performanceFeeBps()).to.equal(PERFORMANCE_FEE_BPS);
    });

    it("should revert when feeVault is the zero address", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          ethers.ZeroAddress,
          PERFORMANCE_FEE_BPS
        )
      ).to.be.revertedWithCustomError(Collector, "InvalidRecipient");
    });

    it("should revert when performanceFeeBps is zero", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          feeVault.address,
          0
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });

    it("should revert when performanceFeeBps exceeds 1000", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          feeVault.address,
          1001
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable getters
  // ---------------------------------------------------------------------------

  describe("Immutable getters", function () {
    it("should return the correct feeVault", async function () {
      expect(await collector.feeVault()).to.equal(feeVault.address);
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

    it("should collect the fee and forward 100% to the feeVault", async function () {
      const expectedFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
      const expectedNet = yieldAmount - expectedFee;

      const userBalBefore = await token.balanceOf(user.address);
      const vaultBalBefore = await token.balanceOf(feeVault.address);

      await collector.connect(user).collectFeeAndForward(
        await token.getAddress(),
        yieldAmount
      );

      // User ends up with: original - yieldAmount (pulled) + netAmount (forwarded back)
      expect(await token.balanceOf(user.address)).to.equal(
        userBalBefore - yieldAmount + expectedNet
      );
      // FeeVault gets 100% of the fee
      expect(await token.balanceOf(feeVault.address)).to.equal(
        vaultBalBefore + expectedFee
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
    it("should revert when called by non-feeVault address", async function () {
      await expect(
        collector.connect(user).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotFeeVault");
    });

    it("should revert when called by contract deployer (owner)", async function () {
      await expect(
        collector.connect(owner).rescueTokens(await token.getAddress())
      ).to.be.revertedWithCustomError(collector, "NotFeeVault");
    });

    it("should allow feeVault to rescue tokens sent directly to the contract", async function () {
      const rescueAmount = ethers.parseEther("42");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      // Accidentally send tokens to the contract
      await token.transfer(collectorAddress, rescueAmount);
      expect(await token.balanceOf(collectorAddress)).to.equal(rescueAmount);

      const balanceBefore = await token.balanceOf(feeVault.address);

      await collector.connect(feeVault).rescueTokens(tokenAddress);

      expect(await token.balanceOf(collectorAddress)).to.equal(0);
      expect(await token.balanceOf(feeVault.address)).to.equal(
        balanceBefore + rescueAmount
      );
    });

    it("should emit TokensRescued event with correct parameters", async function () {
      const rescueAmount = ethers.parseEther("100");
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(collectorAddress, rescueAmount);

      await expect(
        collector.connect(feeVault).rescueTokens(tokenAddress)
      )
        .to.emit(collector, "TokensRescued")
        .withArgs(tokenAddress, rescueAmount);
    });

    it("should not emit TokensRescued when contract has zero balance of the token", async function () {
      const tokenAddress = await token.getAddress();

      // No tokens to rescue, so no event should be emitted
      await expect(
        collector.connect(feeVault).rescueTokens(tokenAddress)
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

      const balBefore = await otherToken.balanceOf(feeVault.address);
      await collector.connect(feeVault).rescueTokens(otherAddress);
      const balAfter = await otherToken.balanceOf(feeVault.address);

      expect(balAfter - balBefore).to.equal(rescueAmount);
    });
  });

  // ===========================================================================
  // ADDITIONAL TESTS
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Constructor boundary values
  // ---------------------------------------------------------------------------

  describe("Constructor boundary values", function () {
    it("should deploy with performanceFeeBps = 1 (minimum)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        feeVault.address,
        1
      );
      await c.waitForDeployment();
      expect(await c.performanceFeeBps()).to.equal(1n);
    });

    it("should deploy with performanceFeeBps = 1000 (maximum)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        feeVault.address,
        1000
      );
      await c.waitForDeployment();
      expect(await c.performanceFeeBps()).to.equal(1000n);
    });

    it("should revert when performanceFeeBps is 1001", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      await expect(
        Collector.deploy(
          feeVault.address,
          1001
        )
      ).to.be.revertedWithCustomError(Collector, "FeeExceedsCap");
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

    it("should forward fees correctly for a second token to the feeVault", async function () {
      const yieldB = ethers.parseEther("5000");
      const collectorAddress = await collector.getAddress();
      const tokenBAddress = await tokenB.getAddress();

      await tokenB.transfer(user.address, yieldB);
      await tokenB.connect(user).approve(collectorAddress, yieldB);

      const vaultBalBefore = await tokenB.balanceOf(feeVault.address);

      await collector.connect(user).collectFeeAndForward(tokenBAddress, yieldB);

      const expectedFee = (yieldB * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;

      // FeeVault gets 100% of the fee
      expect(await tokenB.balanceOf(feeVault.address)).to.equal(
        vaultBalBefore + expectedFee
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Fee distribution precision
  // ---------------------------------------------------------------------------

  describe("Fee distribution precision", function () {
    it("should ensure fee + net == actualReceived (no dust lost)", async function () {
      // Use an amount that can cause rounding: 333 wei at 5% => fee = 16
      const yieldAmount = 333n;
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      const vaultBefore = await token.balanceOf(feeVault.address);
      const userBefore = await token.balanceOf(user.address);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      const vaultAfter = await token.balanceOf(feeVault.address);
      const userAfter = await token.balanceOf(user.address);

      const vaultDelta = vaultAfter - vaultBefore;
      const userDelta = userBefore - userAfter; // User spent this net

      // Total fee (to vault) + net amount (back to user) == yieldAmount
      // userDelta = yieldAmount - netAmount = totalFee
      expect(vaultDelta).to.equal(userDelta);
      // All tokens accounted for
      const netReceived = yieldAmount - userDelta;
      expect(vaultDelta + netReceived).to.equal(yieldAmount);
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

    it("should send 1 wei fee entirely to feeVault", async function () {
      // With a 1 wei total fee, all of it goes to the vault
      const yieldAmount = 20n; // produces 1 wei fee
      const collectorAddress = await collector.getAddress();
      const tokenAddress = await token.getAddress();

      await token.transfer(user.address, yieldAmount);
      await token.connect(user).approve(collectorAddress, yieldAmount);

      const vaultBefore = await token.balanceOf(feeVault.address);

      await collector.connect(user).collectFeeAndForward(tokenAddress, yieldAmount);

      // FeeVault gets the 1 wei fee
      const vaultAfter = await token.balanceOf(feeVault.address);
      expect(vaultAfter - vaultBefore).to.equal(1n);
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
  // Different fee BPS configurations
  // ---------------------------------------------------------------------------

  describe("Different fee BPS configurations", function () {
    it("should collect correct fee at 1 bps (0.01%)", async function () {
      const Collector = await ethers.getContractFactory("OmniYieldFeeCollector");
      const c = await Collector.deploy(
        feeVault.address,
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
        feeVault.address,
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
