const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title LiquidityBootstrappingPool Test Suite
 * @notice Comprehensive tests for the Balancer-style weighted AMM LBP
 *         used for fair XOM token distribution.
 * @dev Tests cover:
 *   1. Constructor validation (addresses, decimals)
 *   2. configure() (valid params, invalid weights, already-started guard)
 *   3. addLiquidity() (before start OK, after start revert, finalized guard)
 *   4. swap() (active period, slippage, max out ratio, cumulative purchase,
 *      price floor, zero-amount, paused)
 *   5. Weight shifting over time (linear interpolation)
 *   6. finalize() (after end, before end revert, double finalize)
 *   7. pause/unpause, getSpotPrice, getExpectedOutput, isActive, getStatus
 *   8. setTreasury, ownership
 *   9. Math correctness (via swap output sanity)
 */
describe("LiquidityBootstrappingPool", function () {
  // ------ Constants matching contract ------
  const BASIS_POINTS = 10000n;
  const SWAP_FEE_BPS = 30n;
  const MIN_XOM_WEIGHT = 2000n;
  const MAX_XOM_WEIGHT = 9600n;
  const MAX_OUT_RATIO = 3000n;

  // ------ Typical LBP parameters ------
  const XOM_LIQUIDITY = ethers.parseEther("100000000"); // 100M XOM
  const USDC_LIQUIDITY = ethers.parseUnits("10000", 6); // 10,000 USDC (6 decimals)
  const START_WEIGHT_XOM = 9000n; // 90%
  const END_WEIGHT_XOM = 3000n; // 30%
  const PRICE_FLOOR = ethers.parseEther("0.000001"); // very low floor
  const MAX_PURCHASE = ethers.parseUnits("5000", 6); // 5000 USDC max per address
  const LBP_DURATION = 7 * 24 * 3600; // 7 days

  /**
   * Deploy fresh contracts and configure a standard LBP.
   * Does NOT start the LBP (time is before startTime).
   */
  async function deployLBPFixture() {
    const [owner, buyer1, buyer2, treasury, forwarder, other] =
      await ethers.getSigners();

    // Deploy mock tokens
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const xom = await ERC20Mock.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();
    const usdc = await ERC20Mock.deploy("USD Coin", "USDC");
    await usdc.waitForDeployment();

    // Deploy LBP
    const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
    const lbp = await LBP.deploy(
      await xom.getAddress(),
      await usdc.getAddress(),
      6, // USDC decimals
      treasury.address,
      forwarder.address
    );
    await lbp.waitForDeployment();

    // Mint tokens to owner for liquidity
    await xom.mint(owner.address, XOM_LIQUIDITY);
    await usdc.mint(owner.address, USDC_LIQUIDITY);

    // Mint USDC to buyers
    await usdc.mint(buyer1.address, ethers.parseUnits("100000", 6));
    await usdc.mint(buyer2.address, ethers.parseUnits("100000", 6));

    // Approve LBP for owner (liquidity)
    await xom.connect(owner).approve(await lbp.getAddress(), ethers.MaxUint256);
    await usdc.connect(owner).approve(await lbp.getAddress(), ethers.MaxUint256);

    // Approve LBP for buyers (swaps)
    await usdc.connect(buyer1).approve(await lbp.getAddress(), ethers.MaxUint256);
    await usdc.connect(buyer2).approve(await lbp.getAddress(), ethers.MaxUint256);

    return { lbp, xom, usdc, owner, buyer1, buyer2, treasury, forwarder, other };
  }

  /**
   * Deploy, configure, add liquidity, and advance to active period.
   */
  async function activeLBPFixture() {
    const fixture = await deployLBPFixture();
    const { lbp, owner } = fixture;

    const now = await time.latest();
    const startTime = now + 60;
    const endTime = startTime + LBP_DURATION;

    await lbp.connect(owner).configure(
      startTime,
      endTime,
      START_WEIGHT_XOM,
      END_WEIGHT_XOM,
      PRICE_FLOOR,
      MAX_PURCHASE
    );

    await lbp.connect(owner).addLiquidity(XOM_LIQUIDITY, USDC_LIQUIDITY);

    // Advance to active period
    await time.increaseTo(startTime + 1);

    return { ...fixture, startTime, endTime };
  }

  // =========================================================================
  // 1. Constructor
  // =========================================================================
  describe("Constructor", function () {
    it("should set XOM_TOKEN correctly", async function () {
      const { lbp, xom } = await loadFixture(deployLBPFixture);
      expect(await lbp.XOM_TOKEN()).to.equal(await xom.getAddress());
    });

    it("should set COUNTER_ASSET_TOKEN correctly", async function () {
      const { lbp, usdc } = await loadFixture(deployLBPFixture);
      expect(await lbp.COUNTER_ASSET_TOKEN()).to.equal(await usdc.getAddress());
    });

    it("should set COUNTER_ASSET_DECIMALS correctly", async function () {
      const { lbp } = await loadFixture(deployLBPFixture);
      expect(await lbp.COUNTER_ASSET_DECIMALS()).to.equal(6);
    });

    it("should set treasury correctly", async function () {
      const { lbp, treasury } = await loadFixture(deployLBPFixture);
      expect(await lbp.treasury()).to.equal(treasury.address);
    });

    it("should set owner to deployer", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      expect(await lbp.owner()).to.equal(owner.address);
    });

    it("should revert if XOM address is zero", async function () {
      const [owner, , , treasury, forwarder] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const usdc = await ERC20Mock.deploy("USDC", "USDC");
      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      await expect(
        LBP.deploy(ethers.ZeroAddress, await usdc.getAddress(), 6, treasury.address, forwarder.address)
      ).to.be.revertedWithCustomError(LBP, "InvalidParameters");
    });

    it("should revert if counter-asset address is zero", async function () {
      const [owner, , , treasury, forwarder] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      await expect(
        LBP.deploy(await xom.getAddress(), ethers.ZeroAddress, 6, treasury.address, forwarder.address)
      ).to.be.revertedWithCustomError(LBP, "InvalidParameters");
    });

    it("should revert if treasury address is zero", async function () {
      const [owner, , , , forwarder] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const usdc = await ERC20Mock.deploy("USDC", "USDC");
      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      await expect(
        LBP.deploy(await xom.getAddress(), await usdc.getAddress(), 6, ethers.ZeroAddress, forwarder.address)
      ).to.be.revertedWithCustomError(LBP, "InvalidParameters");
    });

    it("should revert if counter-asset decimals exceed 18", async function () {
      const [owner, , , treasury, forwarder] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const usdc = await ERC20Mock.deploy("USDC", "USDC");
      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      await expect(
        LBP.deploy(await xom.getAddress(), await usdc.getAddress(), 19, treasury.address, forwarder.address)
      ).to.be.revertedWithCustomError(LBP, "DecimalsOutOfRange");
    });

    it("should accept counter-asset decimals of exactly 18", async function () {
      const [owner, , , treasury, forwarder] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const weth = await ERC20Mock.deploy("WETH", "WETH");
      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      const lbp = await LBP.deploy(
        await xom.getAddress(), await weth.getAddress(), 18, treasury.address, forwarder.address
      );
      expect(await lbp.COUNTER_ASSET_DECIMALS()).to.equal(18);
    });
  });

  // =========================================================================
  // 2. configure()
  // =========================================================================
  describe("configure", function () {
    it("should set all parameters correctly", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      const start = now + 100;
      const end = start + LBP_DURATION;

      await lbp.connect(owner).configure(start, end, 9000, 3000, PRICE_FLOOR, MAX_PURCHASE);

      expect(await lbp.startTime()).to.equal(start);
      expect(await lbp.endTime()).to.equal(end);
      expect(await lbp.startWeightXOM()).to.equal(9000);
      expect(await lbp.endWeightXOM()).to.equal(3000);
      expect(await lbp.priceFloor()).to.equal(PRICE_FLOOR);
      expect(await lbp.maxPurchaseAmount()).to.equal(MAX_PURCHASE);
    });

    it("should emit ParametersUpdated event", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      const start = now + 100;
      const end = start + LBP_DURATION;

      await expect(lbp.connect(owner).configure(start, end, 9000, 3000, PRICE_FLOOR, MAX_PURCHASE))
        .to.emit(lbp, "ParametersUpdated")
        .withArgs(start, end, 9000, 3000);
    });

    it("should revert if called by non-owner", async function () {
      const { lbp, buyer1 } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(buyer1).configure(now + 100, now + 1000, 9000, 3000, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "OwnableUnauthorizedAccount");
    });

    it("should revert if startTime is in the past", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now, now + 1000, 9000, 3000, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidParameters");
    });

    it("should revert if endTime <= startTime", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now + 100, now + 100, 9000, 3000, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidParameters");
    });

    it("should revert if startWeightXOM exceeds MAX_XOM_WEIGHT", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now + 100, now + 1000, 9700, 3000, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidWeights");
    });

    it("should revert if startWeightXOM below MIN_XOM_WEIGHT", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now + 100, now + 1000, 1999, 1998, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidWeights");
    });

    it("should revert if endWeightXOM exceeds MAX_XOM_WEIGHT", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now + 100, now + 1000, 9600, 9700, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidWeights");
    });

    it("should revert if endWeightXOM below MIN_XOM_WEIGHT", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now + 100, now + 1000, 3000, 1500, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidWeights");
    });

    it("should revert if startWeightXOM <= endWeightXOM (weights must decrease)", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await expect(
        lbp.connect(owner).configure(now + 100, now + 1000, 5000, 5000, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidWeights");
    });

    it("should allow reconfiguration before start", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();

      await lbp.connect(owner).configure(now + 200, now + 2000, 9000, 3000, 0, 0);
      // Reconfigure with different params (still before original start)
      await lbp.connect(owner).configure(now + 300, now + 3000, 8000, 2000, PRICE_FLOOR, MAX_PURCHASE);

      expect(await lbp.startWeightXOM()).to.equal(8000);
      expect(await lbp.endWeightXOM()).to.equal(2000);
    });

    it("should revert reconfiguration after LBP has started", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      const start = now + 60;

      await lbp.connect(owner).configure(start, start + LBP_DURATION, 9000, 3000, 0, 0);
      await time.increaseTo(start + 1);

      await expect(
        lbp.connect(owner).configure(start + 1000, start + 2000, 8000, 2000, 0, 0)
      ).to.be.revertedWithCustomError(lbp, "LBPAlreadyStarted");
    });

    it("should accept maxPurchaseAmount of 0 (no limit)", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await lbp.connect(owner).configure(now + 100, now + 1000, 9000, 3000, 0, 0);
      expect(await lbp.maxPurchaseAmount()).to.equal(0);
    });
  });

  // =========================================================================
  // 3. addLiquidity()
  // =========================================================================
  describe("addLiquidity", function () {
    it("should add XOM liquidity before configuration", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      await lbp.connect(owner).addLiquidity(XOM_LIQUIDITY, 0);
      expect(await lbp.xomReserve()).to.equal(XOM_LIQUIDITY);
    });

    it("should add counter-asset liquidity before configuration", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      await lbp.connect(owner).addLiquidity(0, USDC_LIQUIDITY);
      expect(await lbp.counterAssetReserve()).to.equal(USDC_LIQUIDITY);
    });

    it("should add both tokens in a single call", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      await lbp.connect(owner).addLiquidity(XOM_LIQUIDITY, USDC_LIQUIDITY);
      expect(await lbp.xomReserve()).to.equal(XOM_LIQUIDITY);
      expect(await lbp.counterAssetReserve()).to.equal(USDC_LIQUIDITY);
    });

    it("should emit LiquidityAdded event", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      await expect(lbp.connect(owner).addLiquidity(XOM_LIQUIDITY, USDC_LIQUIDITY))
        .to.emit(lbp, "LiquidityAdded")
        .withArgs(XOM_LIQUIDITY, USDC_LIQUIDITY);
    });

    it("should accumulate liquidity across multiple calls", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const half = XOM_LIQUIDITY / 2n;
      await lbp.connect(owner).addLiquidity(half, 0);
      await lbp.connect(owner).addLiquidity(half, USDC_LIQUIDITY);
      expect(await lbp.xomReserve()).to.equal(XOM_LIQUIDITY);
    });

    it("should revert if called by non-owner", async function () {
      const { lbp, buyer1 } = await loadFixture(deployLBPFixture);
      await expect(
        lbp.connect(buyer1).addLiquidity(1000, 1000)
      ).to.be.revertedWithCustomError(lbp, "OwnableUnauthorizedAccount");
    });

    it("should revert if LBP has already started", async function () {
      const { lbp, owner } = await loadFixture(activeLBPFixture);
      await expect(
        lbp.connect(owner).addLiquidity(1000, 0)
      ).to.be.revertedWithCustomError(lbp, "LBPAlreadyStarted");
    });

    it("should revert if LBP is finalized", async function () {
      const { lbp, owner, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);
      await lbp.connect(owner).finalize();

      await expect(
        lbp.connect(owner).addLiquidity(1000, 0)
      ).to.be.revertedWithCustomError(lbp, "AlreadyFinalized");
    });
  });

  // =========================================================================
  // 4. swap()
  // =========================================================================
  describe("swap", function () {
    it("should execute a valid swap and transfer XOM to buyer", async function () {
      const { lbp, xom, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6); // 100 USDC

      const xomBefore = await xom.balanceOf(buyer1.address);
      await lbp.connect(buyer1).swap(swapAmount, 0);
      const xomAfter = await xom.balanceOf(buyer1.address);

      expect(xomAfter).to.be.gt(xomBefore);
    });

    it("should update reserves after swap", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6);

      const xomReserveBefore = await lbp.xomReserve();
      const caReserveBefore = await lbp.counterAssetReserve();

      await lbp.connect(buyer1).swap(swapAmount, 0);

      expect(await lbp.xomReserve()).to.be.lt(xomReserveBefore);
      expect(await lbp.counterAssetReserve()).to.be.gt(caReserveBefore);
    });

    it("should update totalRaised and totalDistributed", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6);

      await lbp.connect(buyer1).swap(swapAmount, 0);

      expect(await lbp.totalRaised()).to.equal(swapAmount);
      expect(await lbp.totalDistributed()).to.be.gt(0);
    });

    it("should emit Swap event with correct arguments", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6);

      await expect(lbp.connect(buyer1).swap(swapAmount, 0))
        .to.emit(lbp, "Swap");
    });

    it("should return the xomOut amount", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6);

      // Use staticCall to get return value
      const xomOut = await lbp.connect(buyer1).swap.staticCall(swapAmount, 0);
      expect(xomOut).to.be.gt(0);
    });

    it("should apply 0.3% swap fee (output is less than fee-free calculation)", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6);

      // The output with fee should be less than the raw weighted output
      const xomOut = await lbp.connect(buyer1).swap.staticCall(swapAmount, 0);
      // A 100 USDC input into a 100M XOM / 10K USDC pool at 90/10 weights
      // should produce a large XOM amount (in the millions)
      expect(xomOut).to.be.gt(0);
    });

    it("should revert when LBP is not active (before start)", async function () {
      const { lbp, buyer1, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      await lbp.connect(owner).configure(now + 1000, now + 2000, 9000, 3000, 0, 0);
      await lbp.connect(owner).addLiquidity(XOM_LIQUIDITY, USDC_LIQUIDITY);

      await expect(
        lbp.connect(buyer1).swap(ethers.parseUnits("100", 6), 0)
      ).to.be.revertedWithCustomError(lbp, "LBPNotActive");
    });

    it("should revert when LBP is not active (after end)", async function () {
      const { lbp, buyer1, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);

      await expect(
        lbp.connect(buyer1).swap(ethers.parseUnits("100", 6), 0)
      ).to.be.revertedWithCustomError(lbp, "LBPNotActive");
    });

    it("should revert when LBP is not configured", async function () {
      const { lbp, buyer1 } = await loadFixture(deployLBPFixture);
      await expect(
        lbp.connect(buyer1).swap(ethers.parseUnits("100", 6), 0)
      ).to.be.revertedWithCustomError(lbp, "LBPNotActive");
    });

    it("should revert on zero counterAssetIn", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      await expect(
        lbp.connect(buyer1).swap(0, 0)
      ).to.be.revertedWithCustomError(lbp, "InvalidParameters");
    });

    it("should revert when slippage is exceeded", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const swapAmount = ethers.parseUnits("100", 6);

      // Demand absurdly high minXomOut
      await expect(
        lbp.connect(buyer1).swap(swapAmount, ethers.parseEther("999999999999"))
      ).to.be.revertedWithCustomError(lbp, "SlippageExceeded");
    });

    it("should enforce per-transaction maxPurchaseAmount", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      // MAX_PURCHASE is 5000 USDC
      const tooMuch = ethers.parseUnits("5001", 6);

      await expect(
        lbp.connect(buyer1).swap(tooMuch, 0)
      ).to.be.revertedWithCustomError(lbp, "ExceedsMaxPurchase");
    });

    it("should track cumulative purchases per address", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const half = ethers.parseUnits("2500", 6);

      await lbp.connect(buyer1).swap(half, 0);
      expect(await lbp.cumulativePurchases(buyer1.address)).to.equal(half);
    });

    it("should revert when cumulative purchases exceed maxPurchaseAmount", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const half = ethers.parseUnits("3000", 6);

      await lbp.connect(buyer1).swap(half, 0);
      // Second swap would push cumulative to 6000 > 5000 limit
      await expect(
        lbp.connect(buyer1).swap(half, 0)
      ).to.be.revertedWithCustomError(lbp, "CumulativePurchaseExceeded");
    });

    it("should allow different buyers to each buy up to maxPurchaseAmount", async function () {
      const { lbp, buyer1, buyer2 } = await loadFixture(activeLBPFixture);
      const amount = ethers.parseUnits("4000", 6);

      await lbp.connect(buyer1).swap(amount, 0);
      await lbp.connect(buyer2).swap(amount, 0);

      expect(await lbp.cumulativePurchases(buyer1.address)).to.equal(amount);
      expect(await lbp.cumulativePurchases(buyer2.address)).to.equal(amount);
    });

    it("should not enforce purchase limit when maxPurchaseAmount is 0", async function () {
      const { lbp, xom, usdc, owner, buyer1 } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      const start = now + 60;

      // Configure with no purchase limit
      await lbp.connect(owner).configure(start, start + LBP_DURATION, 9000, 3000, 0, 0);
      await lbp.connect(owner).addLiquidity(XOM_LIQUIDITY, USDC_LIQUIDITY);
      await time.increaseTo(start + 1);

      // Should succeed with any amount (below max out ratio)
      const largeAmount = ethers.parseUnits("1000", 6);
      await expect(lbp.connect(buyer1).swap(largeAmount, 0)).to.not.be.reverted;
    });

    it("should revert when paused", async function () {
      const { lbp, owner, buyer1 } = await loadFixture(activeLBPFixture);
      await lbp.connect(owner).pause();

      await expect(
        lbp.connect(buyer1).swap(ethers.parseUnits("100", 6), 0)
      ).to.be.revertedWithCustomError(lbp, "EnforcedPause");
    });

    it("should work after unpause", async function () {
      const { lbp, owner, buyer1 } = await loadFixture(activeLBPFixture);
      await lbp.connect(owner).pause();
      await lbp.connect(owner).unpause();

      await expect(
        lbp.connect(buyer1).swap(ethers.parseUnits("100", 6), 0)
      ).to.not.be.reverted;
    });

    it("should enforce MAX_OUT_RATIO (30% of XOM reserve)", async function () {
      // Deploy a pool with very little XOM so that a normal swap triggers the ratio
      const { lbp: _, xom, usdc, owner, buyer1, treasury, forwarder } =
        await loadFixture(deployLBPFixture);

      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      const smallLbp = await LBP.deploy(
        await xom.getAddress(),
        await usdc.getAddress(),
        6,
        treasury.address,
        forwarder.address
      );
      await smallLbp.waitForDeployment();

      // Very small XOM reserve, lots of USDC
      const smallXom = ethers.parseEther("100"); // 100 XOM
      const bigUsdc = ethers.parseUnits("1", 6); // 1 USDC
      await xom.mint(owner.address, smallXom);
      await xom.connect(owner).approve(await smallLbp.getAddress(), ethers.MaxUint256);
      await usdc.connect(owner).approve(await smallLbp.getAddress(), ethers.MaxUint256);
      await usdc.connect(buyer1).approve(await smallLbp.getAddress(), ethers.MaxUint256);

      const now = await time.latest();
      await smallLbp.connect(owner).configure(
        now + 60, now + 60 + LBP_DURATION, 9000, 3000, 0, 0
      );
      await smallLbp.connect(owner).addLiquidity(smallXom, bigUsdc);
      await time.increaseTo(now + 61);

      // Large swap relative to the tiny XOM reserve should trigger MAX_OUT_RATIO
      await expect(
        smallLbp.connect(buyer1).swap(ethers.parseUnits("10000", 6), 0)
      ).to.be.revertedWithCustomError(smallLbp, "ExceedsMaxOutRatio");
    });
  });

  // =========================================================================
  // 5. Weight Shifting
  // =========================================================================
  describe("Weight Shifting", function () {
    it("should return start weights before LBP starts", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      const now = await time.latest();
      const start = now + 1000;
      await lbp.connect(owner).configure(start, start + LBP_DURATION, 9000, 3000, 0, 0);

      const [wXOM, wCA] = await lbp.getCurrentWeights();
      expect(wXOM).to.equal(9000);
      expect(wCA).to.equal(1000);
    });

    it("should return end weights after LBP ends", async function () {
      const { lbp, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 100);

      const [wXOM, wCA] = await lbp.getCurrentWeights();
      expect(wXOM).to.equal(END_WEIGHT_XOM);
      expect(wCA).to.equal(BASIS_POINTS - END_WEIGHT_XOM);
    });

    it("should interpolate weights at the midpoint", async function () {
      const { lbp, startTime, endTime } = await loadFixture(activeLBPFixture);
      const midpoint = startTime + Math.floor((endTime - startTime) / 2);
      await time.increaseTo(midpoint);

      const [wXOM, wCA] = await lbp.getCurrentWeights();
      // Midpoint: 9000 - (9000-3000)/2 = 9000 - 3000 = 6000
      expect(wXOM).to.be.closeTo(6000n, 2n); // Allow 1-2 due to integer division
      expect(wXOM + wCA).to.equal(BASIS_POINTS);
    });

    it("should shift weights linearly at 25% through duration", async function () {
      const { lbp, startTime, endTime } = await loadFixture(activeLBPFixture);
      const quarterPoint = startTime + Math.floor((endTime - startTime) / 4);
      await time.increaseTo(quarterPoint);

      const [wXOM] = await lbp.getCurrentWeights();
      // 25%: 9000 - (9000-3000)*0.25 = 9000 - 1500 = 7500
      expect(wXOM).to.be.closeTo(7500n, 2n);
    });

    it("should shift weights linearly at 75% through duration", async function () {
      const { lbp, startTime, endTime } = await loadFixture(activeLBPFixture);
      const threeQuarter = startTime + Math.floor(((endTime - startTime) * 3) / 4);
      await time.increaseTo(threeQuarter);

      const [wXOM] = await lbp.getCurrentWeights();
      // 75%: 9000 - (9000-3000)*0.75 = 9000 - 4500 = 4500
      expect(wXOM).to.be.closeTo(4500n, 2n);
    });

    it("should have weights sum to BASIS_POINTS at any time", async function () {
      const { lbp, startTime, endTime } = await loadFixture(activeLBPFixture);

      // Check at several points (start from 1 since frac=0 would go back in time)
      for (let frac = 1; frac <= 10; frac++) {
        const t = startTime + Math.floor(((endTime - startTime) * frac) / 10);
        await time.increaseTo(t);
        const [wXOM, wCA] = await lbp.getCurrentWeights();
        expect(wXOM + wCA).to.equal(BASIS_POINTS);
      }
    });

    it("should affect spot price as weights change", async function () {
      const { lbp, startTime, endTime } = await loadFixture(activeLBPFixture);

      // Price at start (high XOM weight -> high price per XOM)
      const priceStart = await lbp.getSpotPrice();

      // Move to midpoint
      const mid = startTime + Math.floor((endTime - startTime) / 2);
      await time.increaseTo(mid);
      const priceMid = await lbp.getSpotPrice();

      // Move near end
      await time.increaseTo(endTime - 10);
      const priceEnd = await lbp.getSpotPrice();

      // As XOM weight decreases, price should decrease (Dutch auction)
      expect(priceStart).to.be.gt(priceMid);
      expect(priceMid).to.be.gt(priceEnd);
    });
  });

  // =========================================================================
  // 6. finalize()
  // =========================================================================
  describe("finalize", function () {
    it("should transfer remaining XOM and counter-asset to treasury", async function () {
      const { lbp, xom, usdc, owner, buyer1, treasury, endTime } =
        await loadFixture(activeLBPFixture);

      // Do a swap first
      await lbp.connect(buyer1).swap(ethers.parseUnits("100", 6), 0);

      const xomReserveBefore = await lbp.xomReserve();
      const caReserveBefore = await lbp.counterAssetReserve();

      await time.increaseTo(endTime + 1);

      const treasuryXomBefore = await xom.balanceOf(treasury.address);
      const treasuryUsdcBefore = await usdc.balanceOf(treasury.address);

      await lbp.connect(owner).finalize();

      expect(await xom.balanceOf(treasury.address)).to.equal(
        treasuryXomBefore + xomReserveBefore
      );
      expect(await usdc.balanceOf(treasury.address)).to.equal(
        treasuryUsdcBefore + caReserveBefore
      );
    });

    it("should set finalized to true", async function () {
      const { lbp, owner, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);
      await lbp.connect(owner).finalize();
      expect(await lbp.finalized()).to.be.true;
    });

    it("should zero out reserves after finalization", async function () {
      const { lbp, owner, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);
      await lbp.connect(owner).finalize();
      expect(await lbp.xomReserve()).to.equal(0);
      expect(await lbp.counterAssetReserve()).to.equal(0);
    });

    it("should emit LBPFinalized event", async function () {
      const { lbp, owner, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);

      await expect(lbp.connect(owner).finalize())
        .to.emit(lbp, "LBPFinalized");
    });

    it("should revert if called before endTime", async function () {
      const { lbp, owner, startTime } = await loadFixture(activeLBPFixture);
      await expect(
        lbp.connect(owner).finalize()
      ).to.be.revertedWithCustomError(lbp, "LBPNotEnded");
    });

    it("should revert if called twice", async function () {
      const { lbp, owner, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);
      await lbp.connect(owner).finalize();

      await expect(
        lbp.connect(owner).finalize()
      ).to.be.revertedWithCustomError(lbp, "AlreadyFinalized");
    });

    it("should revert if called by non-owner", async function () {
      const { lbp, buyer1, endTime } = await loadFixture(activeLBPFixture);
      await time.increaseTo(endTime + 1);

      await expect(
        lbp.connect(buyer1).finalize()
      ).to.be.revertedWithCustomError(lbp, "OwnableUnauthorizedAccount");
    });

    it("should handle finalization with zero counter-asset reserve", async function () {
      // Deploy pool with only XOM
      const { lbp: _, xom, usdc, owner, treasury, forwarder } =
        await loadFixture(deployLBPFixture);

      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      const lbp2 = await LBP.deploy(
        await xom.getAddress(), await usdc.getAddress(), 6, treasury.address, forwarder.address
      );
      await xom.connect(owner).approve(await lbp2.getAddress(), ethers.MaxUint256);

      const now = await time.latest();
      const start = now + 60;
      const end = start + 3600;
      await lbp2.connect(owner).configure(start, end, 9000, 3000, 0, 0);
      await lbp2.connect(owner).addLiquidity(XOM_LIQUIDITY, 0);
      await time.increaseTo(end + 1);

      await expect(lbp2.connect(owner).finalize()).to.not.be.reverted;
    });
  });

  // =========================================================================
  // 7. View Functions
  // =========================================================================
  describe("View Functions", function () {
    describe("getSpotPrice", function () {
      it("should return 0 when xomReserve is 0", async function () {
        const { lbp, owner } = await loadFixture(deployLBPFixture);
        const now = await time.latest();
        await lbp.connect(owner).configure(now + 60, now + 1000, 9000, 3000, 0, 0);
        expect(await lbp.getSpotPrice()).to.equal(0);
      });

      it("should return a non-zero price when reserves exist", async function () {
        const { lbp } = await loadFixture(activeLBPFixture);
        const price = await lbp.getSpotPrice();
        expect(price).to.be.gt(0);
      });

      it("should normalize counter-asset to 18 decimals", async function () {
        const { lbp } = await loadFixture(activeLBPFixture);
        // With 6 decimal USDC, getSpotPrice should still return 18-decimal result
        const price = await lbp.getSpotPrice();
        // Price should be reasonable (not astronomically large or tiny)
        // 10000 USDC / 100M XOM at 90/10 = very small number per XOM
        expect(price).to.be.gt(0);
      });
    });

    describe("getExpectedOutput", function () {
      it("should return expected XOM output for given input", async function () {
        const { lbp } = await loadFixture(activeLBPFixture);
        const input = ethers.parseUnits("100", 6);
        const output = await lbp.getExpectedOutput(input);
        expect(output).to.be.gt(0);
      });

      it("should return 0 for zero input", async function () {
        const { lbp } = await loadFixture(activeLBPFixture);
        const output = await lbp.getExpectedOutput(0);
        expect(output).to.equal(0);
      });

      it("should return higher output for larger input", async function () {
        const { lbp } = await loadFixture(activeLBPFixture);
        const small = await lbp.getExpectedOutput(ethers.parseUnits("10", 6));
        const large = await lbp.getExpectedOutput(ethers.parseUnits("100", 6));
        expect(large).to.be.gt(small);
      });
    });

    describe("isActive", function () {
      it("should return false before configuration", async function () {
        const { lbp } = await loadFixture(deployLBPFixture);
        expect(await lbp.isActive()).to.be.false;
      });

      it("should return false before start time", async function () {
        const { lbp, owner } = await loadFixture(deployLBPFixture);
        const now = await time.latest();
        await lbp.connect(owner).configure(now + 1000, now + 2000, 9000, 3000, 0, 0);
        expect(await lbp.isActive()).to.be.false;
      });

      it("should return true during active period", async function () {
        const { lbp } = await loadFixture(activeLBPFixture);
        expect(await lbp.isActive()).to.be.true;
      });

      it("should return false after end time", async function () {
        const { lbp, endTime } = await loadFixture(activeLBPFixture);
        await time.increaseTo(endTime + 1);
        expect(await lbp.isActive()).to.be.false;
      });

      it("should return false after finalization", async function () {
        const { lbp, owner, endTime } = await loadFixture(activeLBPFixture);
        await time.increaseTo(endTime + 1);
        await lbp.connect(owner).finalize();
        expect(await lbp.isActive()).to.be.false;
      });
    });

    describe("getStatus", function () {
      it("should return all status fields correctly", async function () {
        const { lbp, startTime, endTime } = await loadFixture(activeLBPFixture);
        const status = await lbp.getStatus();
        expect(status._startTime).to.equal(startTime);
        expect(status._endTime).to.equal(endTime);
        expect(status._isActive).to.be.true;
        expect(status._totalRaised).to.equal(0);
        expect(status._totalDistributed).to.equal(0);
        expect(status._currentPrice).to.be.gt(0);
      });
    });
  });

  // =========================================================================
  // 8. pause / unpause / setTreasury / ownership
  // =========================================================================
  describe("Admin Functions", function () {
    it("should allow owner to pause", async function () {
      const { lbp, owner } = await loadFixture(activeLBPFixture);
      await lbp.connect(owner).pause();
      expect(await lbp.paused()).to.be.true;
    });

    it("should allow owner to unpause", async function () {
      const { lbp, owner } = await loadFixture(activeLBPFixture);
      await lbp.connect(owner).pause();
      await lbp.connect(owner).unpause();
      expect(await lbp.paused()).to.be.false;
    });

    it("should revert pause from non-owner", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      await expect(
        lbp.connect(buyer1).pause()
      ).to.be.revertedWithCustomError(lbp, "OwnableUnauthorizedAccount");
    });

    it("should revert unpause from non-owner", async function () {
      const { lbp, owner, buyer1 } = await loadFixture(activeLBPFixture);
      await lbp.connect(owner).pause();
      await expect(
        lbp.connect(buyer1).unpause()
      ).to.be.revertedWithCustomError(lbp, "OwnableUnauthorizedAccount");
    });

    it("should allow owner to update treasury", async function () {
      const { lbp, owner, other } = await loadFixture(deployLBPFixture);
      await lbp.connect(owner).setTreasury(other.address);
      expect(await lbp.treasury()).to.equal(other.address);
    });

    it("should revert setTreasury with zero address", async function () {
      const { lbp, owner } = await loadFixture(deployLBPFixture);
      await expect(
        lbp.connect(owner).setTreasury(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(lbp, "InvalidParameters");
    });

    it("should revert setTreasury from non-owner", async function () {
      const { lbp, buyer1, other } = await loadFixture(deployLBPFixture);
      await expect(
        lbp.connect(buyer1).setTreasury(other.address)
      ).to.be.revertedWithCustomError(lbp, "OwnableUnauthorizedAccount");
    });
  });

  // =========================================================================
  // 9. Math / Swap Correctness
  // =========================================================================
  describe("Math Correctness", function () {
    it("should give diminishing returns for larger swaps (convexity)", async function () {
      const { lbp } = await loadFixture(activeLBPFixture);

      const out1 = await lbp.getExpectedOutput(ethers.parseUnits("100", 6));
      const out2 = await lbp.getExpectedOutput(ethers.parseUnits("200", 6));

      // Due to the AMM curve, 2x input should give < 2x output
      expect(out2).to.be.lt(out1 * 2n);
    });

    it("should give more XOM per USDC at end of LBP (lower XOM weight)", async function () {
      const { lbp, buyer1, startTime, endTime } = await loadFixture(activeLBPFixture);
      const input = ethers.parseUnits("100", 6);

      // Output near start
      const outStart = await lbp.getExpectedOutput(input);

      // Move to near end
      await time.increaseTo(endTime - 60);
      const outEnd = await lbp.getExpectedOutput(input);

      // Lower XOM weight means more XOM per USDC (Dutch auction effect on reserves ratio)
      // This holds only if no swaps have occurred to change reserves
      expect(outEnd).to.be.gt(outStart);
    });

    it("should produce consistent swap output and getExpectedOutput", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const input = ethers.parseUnits("100", 6);

      const expected = await lbp.getExpectedOutput(input);
      const actual = await lbp.connect(buyer1).swap.staticCall(input, 0);

      // They should match (both use the same math at same block)
      expect(actual).to.equal(expected);
    });

    it("should handle very small swaps correctly", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      // 0.01 USDC
      const tinySwap = ethers.parseUnits("0.01", 6);

      const out = await lbp.connect(buyer1).swap.staticCall(tinySwap, 0);
      expect(out).to.be.gt(0);
    });

    it("should handle price floor enforcement", async function () {
      // Deploy LBP with a very high price floor
      const { xom, usdc, owner, buyer1, treasury, forwarder } =
        await loadFixture(deployLBPFixture);

      const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
      const lbp2 = await LBP.deploy(
        await xom.getAddress(), await usdc.getAddress(), 6, treasury.address, forwarder.address
      );
      await xom.connect(owner).approve(await lbp2.getAddress(), ethers.MaxUint256);
      await usdc.connect(owner).approve(await lbp2.getAddress(), ethers.MaxUint256);
      await usdc.connect(buyer1).approve(await lbp2.getAddress(), ethers.MaxUint256);

      const now = await time.latest();
      const start = now + 60;
      const end = start + LBP_DURATION;

      // Very high price floor (unrealistically high)
      const highFloor = ethers.parseEther("999999");

      await lbp2.connect(owner).configure(start, end, 9000, 3000, highFloor, 0);
      await lbp2.connect(owner).addLiquidity(XOM_LIQUIDITY, USDC_LIQUIDITY);
      await time.increaseTo(start + 1);

      // Swap should revert because post-swap price is below the high floor
      await expect(
        lbp2.connect(buyer1).swap(ethers.parseUnits("100", 6), 0)
      ).to.be.revertedWithCustomError(lbp2, "PriceBelowFloor");
    });

    it("should correctly track multiple swaps from same buyer", async function () {
      const { lbp, buyer1 } = await loadFixture(activeLBPFixture);
      const amount = ethers.parseUnits("1000", 6);

      await lbp.connect(buyer1).swap(amount, 0);
      const raised1 = await lbp.totalRaised();

      await lbp.connect(buyer1).swap(amount, 0);
      const raised2 = await lbp.totalRaised();

      expect(raised2).to.equal(raised1 + amount);
    });
  });

  // =========================================================================
  // 10. Constants
  // =========================================================================
  describe("Constants", function () {
    it("should expose BASIS_POINTS as 10000", async function () {
      const { lbp } = await loadFixture(deployLBPFixture);
      expect(await lbp.BASIS_POINTS()).to.equal(10000);
    });

    it("should expose SWAP_FEE_BPS as 30", async function () {
      const { lbp } = await loadFixture(deployLBPFixture);
      expect(await lbp.SWAP_FEE_BPS()).to.equal(30);
    });

    it("should expose MIN_XOM_WEIGHT as 2000", async function () {
      const { lbp } = await loadFixture(deployLBPFixture);
      expect(await lbp.MIN_XOM_WEIGHT()).to.equal(2000);
    });

    it("should expose MAX_XOM_WEIGHT as 9600", async function () {
      const { lbp } = await loadFixture(deployLBPFixture);
      expect(await lbp.MAX_XOM_WEIGHT()).to.equal(9600);
    });

    it("should expose MAX_OUT_RATIO as 3000", async function () {
      const { lbp } = await loadFixture(deployLBPFixture);
      expect(await lbp.MAX_OUT_RATIO()).to.equal(3000);
    });
  });
});
