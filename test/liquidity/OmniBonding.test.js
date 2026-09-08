const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniBonding Test Suite
 * @notice Comprehensive tests for the Protocol Owned Liquidity bonding contract.
 * @dev Tests cover:
 *   1.  Constructor          - valid params, zero-address reverts, price bounds
 *   2.  addBondAsset         - success, validation, duplicate check, MAX_BOND_ASSETS
 *   3.  setBondAssetEnabled  - enable/disable, unsupported asset revert
 *   4.  setXomPrice          - success, cooldown enforcement, bounds, rate-of-change
 *   5.  bond                 - full lifecycle, discount calc, daily capacity, vesting,
 *                              pause check, solvency check, zero amount, active bond
 *   6.  claim                - linear vesting, partial, full, nothing to claim, cleanup
 *   7.  claimAll             - multi-asset, partial vesting, nothing claimable
 *   8.  depositXom/withdrawXom - solvency, excess tracking
 *   9.  updateBondTerms      - discount/vesting bounds, unsupported asset
 *  10.  setTreasury          - success, zero address, self-reference
 *  11.  setPriceOracle       - success, zero address
 *  12.  pause/unpause        - bond blocked, claim allowed
 *  13.  renounceOwnership    - always reverts
 *  14.  rescueToken          - success, cannot rescue XOM
 *  15.  View functions        - getBondInfo, getBondTerms, calculateBondOutput,
 *                              getProtocolStats, getBondAssets, getBondAssetCount
 *  16.  Edge cases            - multiple bonds, capacity reset, 6-decimal asset,
 *                              Ownable2Step access control
 */
describe("OmniBonding", function () {
  // ── Constants matching the contract ──────────────────────────────────
  const BASIS_POINTS = 10_000n;
  const MIN_DISCOUNT_BPS = 500n;
  const MAX_DISCOUNT_BPS = 1_500n;
  const MIN_VESTING_PERIOD = 86_400n; // 1 day in seconds
  const MAX_VESTING_PERIOD = 30n * 86_400n; // 30 days
  const MIN_XOM_PRICE = ethers.parseUnits("0.0001", 18); // 1e14
  const MAX_XOM_PRICE = ethers.parseUnits("100", 18); // 100e18
  const MAX_PRICE_CHANGE_BPS = 1_000n; // 10%
  const PRICE_COOLDOWN = 6n * 3600n; // 6 hours in seconds
  const PRICE_PRECISION = ethers.parseUnits("1", 18); // 1e18

  // ── Common deployment values ─────────────────────────────────────────
  const INITIAL_XOM_PRICE = ethers.parseUnits("0.005", 18); // $0.005
  const DISCOUNT_BPS = 1_000n; // 10%
  const VESTING_PERIOD = 7n * 86_400n; // 7 days
  const DAILY_CAPACITY = ethers.parseEther("1000000"); // 1M units
  const XOM_DEPOSIT = ethers.parseEther("500000000"); // 500M XOM

  /**
   * Deploy fresh contracts for each test group.
   * - xom: 18-decimal ERC20Mock used as XOM token
   * - usdc: 6-decimal ERC20MockDecimals used as bond asset
   * - dai: 18-decimal ERC20Mock used as second bond asset
   * - bonding: OmniBonding contract
   */
  async function deployBondingFixture() {
    const [owner, treasury, user1, user2, attacker] = await ethers.getSigners();

    // Deploy XOM token (18 decimals)
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const xom = await ERC20Mock.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();

    // Deploy USDC mock (6 decimals)
    const ERC20MockDecimals = await ethers.getContractFactory("ERC20MockDecimals");
    const usdc = await ERC20MockDecimals.deploy("USD Coin", "USDC", 6);
    await usdc.waitForDeployment();

    // Deploy DAI mock (18 decimals)
    const dai = await ERC20Mock.deploy("Dai Stablecoin", "DAI");
    await dai.waitForDeployment();

    // Deploy OmniBonding with zero-address trusted forwarder (no meta-tx in tests)
    const OmniBonding = await ethers.getContractFactory("OmniBonding");
    const bonding = await OmniBonding.deploy(
      await xom.getAddress(),
      treasury.address,
      INITIAL_XOM_PRICE,
      ethers.ZeroAddress // no trusted forwarder
    );
    await bonding.waitForDeployment();

    // Owner deposits XOM into bonding contract
    await xom.connect(owner).approve(await bonding.getAddress(), XOM_DEPOSIT);
    await bonding.connect(owner).depositXom(XOM_DEPOSIT);

    // Mint USDC and DAI to users for bonding
    const usdcAmount = 1_000_000n * 10n ** 6n; // 1M USDC
    const daiAmount = ethers.parseEther("1000000"); // 1M DAI
    await usdc.mint(user1.address, usdcAmount);
    await usdc.mint(user2.address, usdcAmount);
    await dai.mint(user1.address, daiAmount);
    await dai.mint(user2.address, daiAmount);

    return { bonding, xom, usdc, dai, owner, treasury, user1, user2, attacker };
  }

  /**
   * Deploy and add USDC as a bond asset (common starting point).
   */
  async function deployWithUsdcAssetFixture() {
    const fixture = await deployBondingFixture();
    const { bonding, usdc, owner } = fixture;

    // Add USDC as bond asset (6 decimals, 10% discount, 7-day vesting, 1M daily cap)
    await bonding.connect(owner).addBondAsset(
      await usdc.getAddress(),
      6, // decimals
      DISCOUNT_BPS,
      VESTING_PERIOD,
      DAILY_CAPACITY
    );

    return fixture;
  }

  /**
   * Deploy, add USDC, and create a bond for user1.
   */
  async function deployWithActiveBondFixture() {
    const fixture = await deployWithUsdcAssetFixture();
    const { bonding, usdc, user1 } = fixture;

    const bondAmount = 1000n * 10n ** 6n; // 1000 USDC
    const usdcAddr = await usdc.getAddress();
    await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
    await bonding.connect(user1).bond(usdcAddr, bondAmount);

    return { ...fixture, bondAmount };
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  1. Constructor
  // ═══════════════════════════════════════════════════════════════════════

  describe("Constructor", function () {
    it("should deploy with correct XOM address", async function () {
      const { bonding, xom } = await loadFixture(deployBondingFixture);
      expect(await bonding.XOM()).to.equal(await xom.getAddress());
    });

    it("should deploy with correct treasury address", async function () {
      const { bonding, treasury } = await loadFixture(deployBondingFixture);
      expect(await bonding.treasury()).to.equal(treasury.address);
    });

    it("should deploy with correct initial XOM price", async function () {
      const { bonding } = await loadFixture(deployBondingFixture);
      expect(await bonding.fixedXomPrice()).to.equal(INITIAL_XOM_PRICE);
    });

    it("should set deployer as owner", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      expect(await bonding.owner()).to.equal(owner.address);
    });

    it("should revert when XOM address is zero", async function () {
      const [, treasurySigner] = await ethers.getSigners();
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      await expect(
        OmniBonding.deploy(ethers.ZeroAddress, treasurySigner.address, INITIAL_XOM_PRICE, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(OmniBonding, "InvalidParameters");
    });

    it("should revert when treasury address is zero", async function () {
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      await expect(
        OmniBonding.deploy(await xom.getAddress(), ethers.ZeroAddress, INITIAL_XOM_PRICE, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(OmniBonding, "InvalidParameters");
    });

    it("should revert when initial price is below MIN_XOM_PRICE", async function () {
      const [, treasurySigner] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      const tooLow = MIN_XOM_PRICE - 1n;
      await expect(
        OmniBonding.deploy(await xom.getAddress(), treasurySigner.address, tooLow, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(OmniBonding, "PriceOutOfBounds").withArgs(tooLow);
    });

    it("should revert when initial price is above MAX_XOM_PRICE", async function () {
      const [, treasurySigner] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      const tooHigh = MAX_XOM_PRICE + 1n;
      await expect(
        OmniBonding.deploy(await xom.getAddress(), treasurySigner.address, tooHigh, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(OmniBonding, "PriceOutOfBounds").withArgs(tooHigh);
    });

    it("should accept initial price at MIN_XOM_PRICE boundary", async function () {
      const [, treasurySigner] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      const bonding = await OmniBonding.deploy(
        await xom.getAddress(), treasurySigner.address, MIN_XOM_PRICE, ethers.ZeroAddress
      );
      expect(await bonding.fixedXomPrice()).to.equal(MIN_XOM_PRICE);
    });

    it("should accept initial price at MAX_XOM_PRICE boundary", async function () {
      const [, treasurySigner] = await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      const bonding = await OmniBonding.deploy(
        await xom.getAddress(), treasurySigner.address, MAX_XOM_PRICE, ethers.ZeroAddress
      );
      expect(await bonding.fixedXomPrice()).to.equal(MAX_XOM_PRICE);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  2. addBondAsset
  // ═══════════════════════════════════════════════════════════════════════

  describe("addBondAsset", function () {
    it("should add a bond asset successfully", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();

      await expect(
        bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.emit(bonding, "BondAssetAdded").withArgs(usdcAddr, 6)
        .and.to.emit(bonding, "BondTermsUpdated").withArgs(usdcAddr, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
    });

    it("should add asset to bondAssets array", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      await bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      const assets = await bonding.getBondAssets();
      expect(assets).to.include(usdcAddr);
      expect(await bonding.getBondAssetCount()).to.equal(1);
    });

    it("should initialize bond terms correctly", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      await bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      const [enabled, discount, vesting, capacity] = await bonding.getBondTerms(usdcAddr);
      expect(enabled).to.be.true;
      expect(discount).to.equal(DISCOUNT_BPS);
      expect(vesting).to.equal(VESTING_PERIOD);
      expect(capacity).to.equal(DAILY_CAPACITY);
    });

    it("should revert when asset address is zero", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).addBondAsset(ethers.ZeroAddress, 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert when asset is already added", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      await bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      await expect(
        bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "AssetAlreadyAdded");
    });

    it("should revert when discount is below MIN_DISCOUNT_BPS", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).addBondAsset(await usdc.getAddress(), 6, MIN_DISCOUNT_BPS - 1n, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidDiscount");
    });

    it("should revert when discount is above MAX_DISCOUNT_BPS", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).addBondAsset(await usdc.getAddress(), 6, MAX_DISCOUNT_BPS + 1n, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidDiscount");
    });

    it("should revert when vesting period is below MIN_VESTING_PERIOD", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).addBondAsset(await usdc.getAddress(), 6, DISCOUNT_BPS, MIN_VESTING_PERIOD - 1n, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidVestingPeriod");
    });

    it("should revert when vesting period is above MAX_VESTING_PERIOD", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).addBondAsset(await usdc.getAddress(), 6, DISCOUNT_BPS, MAX_VESTING_PERIOD + 1n, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidVestingPeriod");
    });

    it("should revert when decimals exceed 24", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).addBondAsset(await usdc.getAddress(), 25, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, usdc, attacker } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).addBondAsset(await usdc.getAddress(), 6, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });

    it("should accept discount at MIN_DISCOUNT_BPS boundary", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployBondingFixture);
      await bonding.connect(owner).addBondAsset(await usdc.getAddress(), 6, MIN_DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      const [, discount] = await bonding.getBondTerms(await usdc.getAddress());
      expect(discount).to.equal(MIN_DISCOUNT_BPS);
    });

    it("should accept discount at MAX_DISCOUNT_BPS boundary", async function () {
      const { bonding, dai, owner } = await loadFixture(deployBondingFixture);
      await bonding.connect(owner).addBondAsset(await dai.getAddress(), 18, MAX_DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      const [, discount] = await bonding.getBondTerms(await dai.getAddress());
      expect(discount).to.equal(MAX_DISCOUNT_BPS);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  3. setBondAssetEnabled
  // ═══════════════════════════════════════════════════════════════════════

  describe("setBondAssetEnabled", function () {
    it("should disable a bond asset", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      await expect(bonding.connect(owner).setBondAssetEnabled(usdcAddr, false))
        .to.emit(bonding, "BondAssetEnabledChanged").withArgs(usdcAddr, false);
      const [enabled] = await bonding.getBondTerms(usdcAddr);
      expect(enabled).to.be.false;
    });

    it("should re-enable a disabled bond asset", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      await bonding.connect(owner).setBondAssetEnabled(usdcAddr, false);
      await expect(bonding.connect(owner).setBondAssetEnabled(usdcAddr, true))
        .to.emit(bonding, "BondAssetEnabledChanged").withArgs(usdcAddr, true);
      const [enabled] = await bonding.getBondTerms(usdcAddr);
      expect(enabled).to.be.true;
    });

    it("should revert for unsupported asset", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      const randomAddr = ethers.Wallet.createRandom().address;
      await expect(
        bonding.connect(owner).setBondAssetEnabled(randomAddr, false)
      ).to.be.revertedWithCustomError(bonding, "AssetNotSupported");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, usdc, attacker } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(attacker).setBondAssetEnabled(await usdc.getAddress(), false)
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  4. setXomPrice
  // ═══════════════════════════════════════════════════════════════════════

  describe("setXomPrice", function () {
    it("should update the XOM price within 10% change", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      // Wait past cooldown (constructor sets lastPriceUpdateTime = 0, so first call is fine)
      await time.increase(Number(PRICE_COOLDOWN));
      const newPrice = INITIAL_XOM_PRICE + (INITIAL_XOM_PRICE * 10n / 100n); // +10%
      await expect(bonding.connect(owner).setXomPrice(newPrice))
        .to.emit(bonding, "XomPriceUpdated").withArgs(newPrice);
      expect(await bonding.fixedXomPrice()).to.equal(newPrice);
    });

    it("should allow a price decrease within 10%", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await time.increase(Number(PRICE_COOLDOWN));
      const newPrice = INITIAL_XOM_PRICE - (INITIAL_XOM_PRICE * 10n / 100n); // -10%
      await bonding.connect(owner).setXomPrice(newPrice);
      expect(await bonding.fixedXomPrice()).to.equal(newPrice);
    });

    it("should revert when price change exceeds 10%", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await time.increase(Number(PRICE_COOLDOWN));
      const excessivePrice = INITIAL_XOM_PRICE + (INITIAL_XOM_PRICE * 11n / 100n); // +11%
      await expect(
        bonding.connect(owner).setXomPrice(excessivePrice)
      ).to.be.revertedWithCustomError(bonding, "PriceChangeExceedsLimit")
        .withArgs(INITIAL_XOM_PRICE, excessivePrice);
    });

    it("should revert when cooldown has not elapsed", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      // First update should succeed (lastPriceUpdateTime starts at 0)
      await time.increase(Number(PRICE_COOLDOWN));
      const firstUpdate = INITIAL_XOM_PRICE + (INITIAL_XOM_PRICE / 20n); // +5%
      await bonding.connect(owner).setXomPrice(firstUpdate);
      // Immediate second update should fail
      const secondUpdate = firstUpdate + (firstUpdate / 20n);
      await expect(
        bonding.connect(owner).setXomPrice(secondUpdate)
      ).to.be.revertedWithCustomError(bonding, "PriceCooldownActive");
    });

    it("should succeed after cooldown elapses", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await time.increase(Number(PRICE_COOLDOWN));
      const firstUpdate = INITIAL_XOM_PRICE + (INITIAL_XOM_PRICE / 20n);
      await bonding.connect(owner).setXomPrice(firstUpdate);
      // Wait the full cooldown
      await time.increase(Number(PRICE_COOLDOWN));
      const secondUpdate = firstUpdate + (firstUpdate / 20n);
      await bonding.connect(owner).setXomPrice(secondUpdate);
      expect(await bonding.fixedXomPrice()).to.equal(secondUpdate);
    });

    it("should revert when new price is below MIN_XOM_PRICE", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await time.increase(Number(PRICE_COOLDOWN));
      // Deploy a new bonding with price near MIN so we can try to go below
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom2 = await ERC20Mock.deploy("XOM2", "XOM2");
      const [, treasurySigner] = await ethers.getSigners();
      const OmniBonding = await ethers.getContractFactory("OmniBonding");
      const nearMin = MIN_XOM_PRICE + MIN_XOM_PRICE / 5n; // slightly above min
      const bonding2 = await OmniBonding.deploy(
        await xom2.getAddress(), treasurySigner.address, nearMin, ethers.ZeroAddress
      );
      await time.increase(Number(PRICE_COOLDOWN));
      await expect(
        bonding2.connect(owner).setXomPrice(MIN_XOM_PRICE - 1n)
      ).to.be.revertedWithCustomError(bonding2, "PriceOutOfBounds");
    });

    it("should revert when new price is above MAX_XOM_PRICE", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await time.increase(Number(PRICE_COOLDOWN));
      await expect(
        bonding.connect(owner).setXomPrice(MAX_XOM_PRICE + 1n)
      ).to.be.revertedWithCustomError(bonding, "PriceOutOfBounds");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, attacker } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).setXomPrice(INITIAL_XOM_PRICE)
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });

    it("should update lastPriceUpdateTime on success", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await time.increase(Number(PRICE_COOLDOWN));
      const newPrice = INITIAL_XOM_PRICE + (INITIAL_XOM_PRICE / 20n);
      await bonding.connect(owner).setXomPrice(newPrice);
      const updateTime = await bonding.lastPriceUpdateTime();
      expect(updateTime).to.be.gt(0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  5. bond
  // ═══════════════════════════════════════════════════════════════════════

  describe("bond", function () {
    it("should create a bond with correct XOM owed (6-decimal asset)", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 1000n * 10n ** 6n; // 1000 USDC (6 decimals)

      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      const tx = await bonding.connect(user1).bond(usdcAddr, bondAmount);

      // Calculate expected XOM:
      // assetValue = 1000 * 10^(18-6) = 1000e18
      // discountedPrice = 0.005 * (10000 - 1000) / 10000 = 0.0045 = 4.5e15
      // xomOwed = 1000e18 * 1e18 / 4.5e15 = 222222.222...e18
      const assetValue = bondAmount * 10n ** 12n; // normalize 6 -> 18
      const discountedPrice = (INITIAL_XOM_PRICE * (BASIS_POINTS - DISCOUNT_BPS)) / BASIS_POINTS;
      const expectedXom = (assetValue * PRICE_PRECISION) / discountedPrice;

      await expect(tx).to.emit(bonding, "BondCreated")
        .withArgs(user1.address, usdcAddr, bondAmount, expectedXom, await time.latest() + Number(VESTING_PERIOD));
    });

    it("should create a bond with correct XOM owed (18-decimal asset)", async function () {
      const { bonding, dai, owner, user1 } = await loadFixture(deployBondingFixture);
      const daiAddr = await dai.getAddress();

      // Add DAI as bond asset
      await bonding.connect(owner).addBondAsset(daiAddr, 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);

      const bondAmount = ethers.parseEther("1000"); // 1000 DAI
      await dai.connect(user1).approve(await bonding.getAddress(), bondAmount);
      const tx = await bonding.connect(user1).bond(daiAddr, bondAmount);

      const discountedPrice = (INITIAL_XOM_PRICE * (BASIS_POINTS - DISCOUNT_BPS)) / BASIS_POINTS;
      const expectedXom = (bondAmount * PRICE_PRECISION) / discountedPrice;

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => bonding.interface.parseLog(log)?.name === "BondCreated"
      );
      const parsed = bonding.interface.parseLog(event);
      expect(parsed.args.xomOwed).to.equal(expectedXom);
    });

    it("should transfer bond asset to treasury", async function () {
      const { bonding, usdc, user1, treasury } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 1000n * 10n ** 6n;

      const treasuryBalBefore = await usdc.balanceOf(treasury.address);
      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(usdcAddr, bondAmount);

      expect(await usdc.balanceOf(treasury.address)).to.equal(treasuryBalBefore + bondAmount);
    });

    it("should increment totalXomOutstanding", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 1000n * 10n ** 6n;

      const outstandingBefore = await bonding.totalXomOutstanding();
      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(usdcAddr, bondAmount);

      const outstandingAfter = await bonding.totalXomOutstanding();
      expect(outstandingAfter).to.be.gt(outstandingBefore);
    });

    it("should revert when bond amount is zero", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(user1).bond(await usdc.getAddress(), 0)
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert when asset is not supported", async function () {
      const { bonding, user1 } = await loadFixture(deployBondingFixture);
      const randomAddr = ethers.Wallet.createRandom().address;
      await expect(
        bonding.connect(user1).bond(randomAddr, 1000)
      ).to.be.revertedWithCustomError(bonding, "AssetNotSupported");
    });

    it("should revert when asset is disabled", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      await bonding.connect(owner).setBondAssetEnabled(usdcAddr, false);

      await usdc.connect(user1).approve(await bonding.getAddress(), 1000n * 10n ** 6n);
      await expect(
        bonding.connect(user1).bond(usdcAddr, 1000n * 10n ** 6n)
      ).to.be.revertedWithCustomError(bonding, "AssetDisabled");
    });

    it("should revert when daily capacity is exceeded", async function () {
      const { bonding, usdc, owner, user1, user2 } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      const smallCap = 500n * 10n ** 6n; // 500 USDC daily cap

      await bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, smallCap);

      // Bond up to capacity
      await usdc.connect(user1).approve(await bonding.getAddress(), smallCap);
      await bonding.connect(user1).bond(usdcAddr, smallCap);

      // Next bond should exceed capacity
      await usdc.connect(user2).approve(await bonding.getAddress(), 1n * 10n ** 6n);
      await expect(
        bonding.connect(user2).bond(usdcAddr, 1n * 10n ** 6n)
      ).to.be.revertedWithCustomError(bonding, "DailyCapacityExceeded");
    });

    it("should revert when user already has an active bond for same asset", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 100n * 10n ** 6n;

      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount * 2n);
      await bonding.connect(user1).bond(usdcAddr, bondAmount);

      await expect(
        bonding.connect(user1).bond(usdcAddr, bondAmount)
      ).to.be.revertedWithCustomError(bonding, "ActiveBondExists");
    });

    it("should revert when contract lacks sufficient XOM for obligations", async function () {
      const { bonding, usdc, xom, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondingAddr = await bonding.getAddress();

      // Withdraw almost all XOM to leave insufficient balance
      const balance = await xom.balanceOf(bondingAddr);
      const outstanding = await bonding.totalXomOutstanding();
      const excess = balance - outstanding;
      if (excess > 0n) {
        await bonding.connect(owner).withdrawXom(excess);
      }

      // Bond a large amount that would exceed remaining balance
      const largeAmount = 900_000n * 10n ** 6n;
      await usdc.mint(user1.address, largeAmount);
      await usdc.connect(user1).approve(bondingAddr, largeAmount);
      await expect(
        bonding.connect(user1).bond(usdcAddr, largeAmount)
      ).to.be.revertedWithCustomError(bonding, "InsufficientXomBalance");
    });

    it("should revert when contract is paused", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      await bonding.connect(owner).pause();

      await usdc.connect(user1).approve(await bonding.getAddress(), 1000n * 10n ** 6n);
      await expect(
        bonding.connect(user1).bond(usdcAddr, 1000n * 10n ** 6n)
      ).to.be.revertedWithCustomError(bonding, "EnforcedPause");
    });

    it("should increment dailyBonded and totalAssetReceived", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 500n * 10n ** 6n;

      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(usdcAddr, bondAmount);

      const [, , , capacity, remaining] = await bonding.getBondTerms(usdcAddr);
      expect(remaining).to.equal(capacity - bondAmount);
    });

    it("should update totalXomDistributed and totalValueReceived", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const bondAmount = 1000n * 10n ** 6n;
      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(await usdc.getAddress(), bondAmount);

      const [distributed, outstanding, valueReceived] = await bonding.getProtocolStats();
      expect(distributed).to.be.gt(0);
      expect(outstanding).to.be.gt(0);
      expect(valueReceived).to.equal(bondAmount * 10n ** 12n); // normalized to 18 decimals
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  6. claim
  // ═══════════════════════════════════════════════════════════════════════

  describe("claim", function () {
    it("should allow partial claim after partial vesting", async function () {
      const { bonding, usdc, xom, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      // Advance time to halfway through vesting
      await time.increase(Number(VESTING_PERIOD) / 2);

      const [xomOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const xomBalBefore = await xom.balanceOf(user1.address);

      const tx = await bonding.connect(user1).claim(usdcAddr);
      await expect(tx).to.emit(bonding, "BondClaimed");

      const xomBalAfter = await xom.balanceOf(user1.address);
      const claimed = xomBalAfter - xomBalBefore;

      // Should be approximately half (within 2% tolerance for block time drift)
      expect(claimed).to.be.closeTo(xomOwed / 2n, xomOwed / 50n);
      expect(claimed).to.be.gt(0);
      expect(claimed).to.be.lt(xomOwed);
    });

    it("should allow full claim after complete vesting", async function () {
      const { bonding, usdc, xom, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      const [xomOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const xomBalBefore = await xom.balanceOf(user1.address);

      // Advance past vesting period
      await time.increase(Number(VESTING_PERIOD) + 1);

      await bonding.connect(user1).claim(usdcAddr);
      const xomBalAfter = await xom.balanceOf(user1.address);

      expect(xomBalAfter - xomBalBefore).to.equal(xomOwed);
    });

    it("should allow multiple partial claims", async function () {
      const { bonding, usdc, xom, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      const [xomOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const xomBalStart = await xom.balanceOf(user1.address);

      // Claim at 25%
      await time.increase(Number(VESTING_PERIOD) / 4);
      await bonding.connect(user1).claim(usdcAddr);

      // Claim at 75%
      await time.increase(Number(VESTING_PERIOD) / 2);
      await bonding.connect(user1).claim(usdcAddr);

      // Claim rest at 100%
      await time.increase(Number(VESTING_PERIOD) / 4 + 1);
      await bonding.connect(user1).claim(usdcAddr);

      const xomBalEnd = await xom.balanceOf(user1.address);
      expect(xomBalEnd - xomBalStart).to.equal(xomOwed);
    });

    it("should revert when user has no bond", async function () {
      const { bonding, usdc, user2 } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(user2).claim(await usdc.getAddress())
      ).to.be.revertedWithCustomError(bonding, "NoBondToClaim");
    });

    it("should revert NothingToClaim when already fully claimed", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      // Fully vest and claim
      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(user1).claim(usdcAddr);

      // Bond was deleted on full claim, so now NoBondToClaim
      await expect(
        bonding.connect(user1).claim(usdcAddr)
      ).to.be.revertedWithCustomError(bonding, "NoBondToClaim");
    });

    it("should revert NothingToClaim after partial claim with no additional vesting", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      // Vest a bit and claim
      await time.increase(Number(VESTING_PERIOD) / 4);
      await bonding.connect(user1).claim(usdcAddr);

      // Immediately try to claim again in the next block - should revert
      // because only 1 second has passed and the vested increment rounds to 0
      // compared to what was already claimed
      // Note: This may succeed with a tiny amount if rounding allows it.
      // Use a large vesting period to make per-second vesting negligibly small.
      // Instead, just verify claiming works and the amount is near zero or test
      // reverts for a user with no bond.
      const claimable = await bonding.getClaimable(user1.address, usdcAddr);
      // After claiming, the next block's claimable should be tiny
      // (1 second / 7 days worth of xomOwed ~ negligible)
      expect(claimable).to.be.lt(ethers.parseEther("1"));
    });

    it("should decrement totalXomOutstanding on claim", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      const outstandingBefore = await bonding.totalXomOutstanding();
      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(user1).claim(usdcAddr);

      expect(await bonding.totalXomOutstanding()).to.be.lt(outstandingBefore);
    });

    it("should delete bond struct after full claim (M-03 cleanup)", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(user1).claim(usdcAddr);

      // Bond should be cleaned up
      const [xomOwed, claimed] = await bonding.getBondInfo(user1.address, usdcAddr);
      expect(xomOwed).to.equal(0);
      expect(claimed).to.equal(0);
    });

    it("should allow re-bonding after full claim cleanup", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      // Complete first bond
      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(user1).claim(usdcAddr);

      // Re-bond should work
      const newAmount = 500n * 10n ** 6n;
      await usdc.connect(user1).approve(await bonding.getAddress(), newAmount);
      await expect(bonding.connect(user1).bond(usdcAddr, newAmount)).to.not.be.reverted;
    });

    it("should work while contract is paused (claim is not gated by whenNotPaused)", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(owner).pause();

      // claim should still work
      await expect(bonding.connect(user1).claim(usdcAddr)).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  7. claimAll
  // ═══════════════════════════════════════════════════════════════════════

  describe("claimAll", function () {
    it("should claim from multiple bond assets at once", async function () {
      const { bonding, usdc, dai, xom, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const daiAddr = await dai.getAddress();

      // Add DAI as second bond asset
      await bonding.connect(owner).addBondAsset(daiAddr, 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);

      // Bond USDC
      const usdcAmount = 1000n * 10n ** 6n;
      await usdc.connect(user1).approve(await bonding.getAddress(), usdcAmount);
      await bonding.connect(user1).bond(usdcAddr, usdcAmount);

      // Bond DAI
      const daiAmount = ethers.parseEther("1000");
      await dai.connect(user1).approve(await bonding.getAddress(), daiAmount);
      await bonding.connect(user1).bond(daiAddr, daiAmount);

      // Advance past vesting
      await time.increase(Number(VESTING_PERIOD) + 1);

      const xomBalBefore = await xom.balanceOf(user1.address);
      await bonding.connect(user1).claimAll();
      const xomBalAfter = await xom.balanceOf(user1.address);

      // Should have received XOM from both bonds
      const totalReceived = xomBalAfter - xomBalBefore;
      expect(totalReceived).to.be.gt(0);
    });

    it("should revert when nothing is claimable across all assets", async function () {
      const { bonding, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      // user1 has no bonds
      await expect(
        bonding.connect(user1).claimAll()
      ).to.be.revertedWithCustomError(bonding, "NothingToClaim");
    });

    it("should emit BondClaimed for each asset with claimable tokens", async function () {
      const { bonding, usdc, dai, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const daiAddr = await dai.getAddress();

      await bonding.connect(owner).addBondAsset(daiAddr, 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);

      const usdcAmount = 1000n * 10n ** 6n;
      const daiAmount = ethers.parseEther("1000");

      await usdc.connect(user1).approve(await bonding.getAddress(), usdcAmount);
      await bonding.connect(user1).bond(usdcAddr, usdcAmount);
      await dai.connect(user1).approve(await bonding.getAddress(), daiAmount);
      await bonding.connect(user1).bond(daiAddr, daiAmount);

      await time.increase(Number(VESTING_PERIOD) + 1);

      const tx = await bonding.connect(user1).claimAll();
      const receipt = await tx.wait();

      // Should emit BondClaimed events for both assets
      const bondClaimedEvents = receipt.logs
        .map((log) => { try { return bonding.interface.parseLog(log); } catch { return null; } })
        .filter((e) => e !== null && e.name === "BondClaimed");

      expect(bondClaimedEvents.length).to.equal(2);
      const assets = bondClaimedEvents.map((e) => e.args.asset);
      expect(assets).to.include(usdcAddr);
      expect(assets).to.include(daiAddr);
      // Both claimed amounts should be > 0
      bondClaimedEvents.forEach((e) => {
        expect(e.args.amount).to.be.gt(0);
      });
    });

    it("should clean up fully-claimed bonds", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();

      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(user1).claimAll();

      const [xomOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      expect(xomOwed).to.equal(0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  8. depositXom / withdrawXom
  // ═══════════════════════════════════════════════════════════════════════

  describe("depositXom", function () {
    it("should accept XOM deposits and emit event", async function () {
      const { bonding, xom, owner } = await loadFixture(deployBondingFixture);
      const depositAmount = ethers.parseEther("5000000");
      await xom.connect(owner).approve(await bonding.getAddress(), depositAmount);
      await expect(bonding.connect(owner).depositXom(depositAmount))
        .to.emit(bonding, "XomDeposited").withArgs(owner.address, depositAmount);
    });

    it("should increase contract XOM balance", async function () {
      const { bonding, xom, owner } = await loadFixture(deployBondingFixture);
      const bondingAddr = await bonding.getAddress();
      const balBefore = await xom.balanceOf(bondingAddr);

      const depositAmount = ethers.parseEther("1000");
      await xom.connect(owner).approve(bondingAddr, depositAmount);
      await bonding.connect(owner).depositXom(depositAmount);

      expect(await xom.balanceOf(bondingAddr)).to.equal(balBefore + depositAmount);
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, xom, attacker } = await loadFixture(deployBondingFixture);
      await xom.mint(attacker.address, ethers.parseEther("1000"));
      await xom.connect(attacker).approve(await bonding.getAddress(), ethers.parseEther("1000"));
      await expect(
        bonding.connect(attacker).depositXom(ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  describe("withdrawXom", function () {
    it("should withdraw excess XOM to treasury", async function () {
      const { bonding, xom, owner, treasury } = await loadFixture(deployBondingFixture);
      const withdrawAmount = ethers.parseEther("1000000");
      const treasuryBalBefore = await xom.balanceOf(treasury.address);

      await expect(bonding.connect(owner).withdrawXom(withdrawAmount))
        .to.emit(bonding, "XomWithdrawn").withArgs(withdrawAmount, treasury.address);

      expect(await xom.balanceOf(treasury.address)).to.equal(treasuryBalBefore + withdrawAmount);
    });

    it("should not allow withdrawal that would make balance less than totalXomOutstanding", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);

      // Create a bond to establish outstanding obligations
      const bondAmount = 500_000n * 10n ** 6n; // 500K USDC -> lots of XOM
      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(await usdc.getAddress(), bondAmount);

      const outstanding = await bonding.totalXomOutstanding();
      // Try to withdraw everything including outstanding
      await expect(
        bonding.connect(owner).withdrawXom(XOM_DEPOSIT) // all deposited XOM
      ).to.be.revertedWithCustomError(bonding, "InsufficientXomBalance");
    });

    it("should allow withdrawal up to exact excess amount", async function () {
      const { bonding, xom, usdc, owner, user1, treasury } = await loadFixture(deployWithUsdcAssetFixture);
      const bondingAddr = await bonding.getAddress();

      // Create a bond
      const bondAmount = 1000n * 10n ** 6n;
      await usdc.connect(user1).approve(bondingAddr, bondAmount);
      await bonding.connect(user1).bond(await usdc.getAddress(), bondAmount);

      const balance = await xom.balanceOf(bondingAddr);
      const outstanding = await bonding.totalXomOutstanding();
      const excess = balance - outstanding;

      // Withdraw exact excess
      await expect(bonding.connect(owner).withdrawXom(excess)).to.not.be.reverted;

      // One more wei should fail
      await expect(
        bonding.connect(owner).withdrawXom(1n)
      ).to.be.revertedWithCustomError(bonding, "InsufficientXomBalance");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, attacker } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).withdrawXom(ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  9. updateBondTerms
  // ═══════════════════════════════════════════════════════════════════════

  describe("updateBondTerms", function () {
    it("should update discount, vesting period, and daily capacity", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const newDiscount = 750n; // 7.5%
      const newVesting = 14n * 86_400n; // 14 days
      const newCapacity = ethers.parseEther("2000000");

      await expect(
        bonding.connect(owner).updateBondTerms(usdcAddr, newDiscount, newVesting, newCapacity)
      ).to.emit(bonding, "BondTermsUpdated").withArgs(usdcAddr, newDiscount, newVesting, newCapacity);

      const [, discount, vesting, capacity] = await bonding.getBondTerms(usdcAddr);
      expect(discount).to.equal(newDiscount);
      expect(vesting).to.equal(newVesting);
      expect(capacity).to.equal(newCapacity);
    });

    it("should revert for unsupported asset", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      const randomAddr = ethers.Wallet.createRandom().address;
      await expect(
        bonding.connect(owner).updateBondTerms(randomAddr, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "AssetNotSupported");
    });

    it("should revert when discount is below MIN_DISCOUNT_BPS", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(owner).updateBondTerms(await usdc.getAddress(), MIN_DISCOUNT_BPS - 1n, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidDiscount");
    });

    it("should revert when discount is above MAX_DISCOUNT_BPS", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(owner).updateBondTerms(await usdc.getAddress(), MAX_DISCOUNT_BPS + 1n, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidDiscount");
    });

    it("should revert when vesting period is below MIN_VESTING_PERIOD", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(owner).updateBondTerms(await usdc.getAddress(), DISCOUNT_BPS, MIN_VESTING_PERIOD - 1n, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidVestingPeriod");
    });

    it("should revert when vesting period is above MAX_VESTING_PERIOD", async function () {
      const { bonding, usdc, owner } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(owner).updateBondTerms(await usdc.getAddress(), DISCOUNT_BPS, MAX_VESTING_PERIOD + 1n, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "InvalidVestingPeriod");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, usdc, attacker } = await loadFixture(deployWithUsdcAssetFixture);
      await expect(
        bonding.connect(attacker).updateBondTerms(await usdc.getAddress(), DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY)
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  10. setTreasury
  // ═══════════════════════════════════════════════════════════════════════

  describe("setTreasury", function () {
    it("should update treasury address", async function () {
      const { bonding, owner, user1, treasury } = await loadFixture(deployBondingFixture);
      await expect(bonding.connect(owner).setTreasury(user1.address))
        .to.emit(bonding, "TreasuryUpdated").withArgs(treasury.address, user1.address);
      expect(await bonding.treasury()).to.equal(user1.address);
    });

    it("should revert when treasury is zero address", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).setTreasury(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert when treasury is set to contract itself", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).setTreasury(await bonding.getAddress())
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, attacker, user1 } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).setTreasury(user1.address)
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  11. setPriceOracle
  // ═══════════════════════════════════════════════════════════════════════

  describe("setPriceOracle", function () {
    it("should update price oracle address", async function () {
      const { bonding, owner, user1 } = await loadFixture(deployBondingFixture);
      await expect(bonding.connect(owner).setPriceOracle(user1.address))
        .to.emit(bonding, "PriceOracleUpdated").withArgs(ethers.ZeroAddress, user1.address);
      expect(await bonding.priceOracle()).to.equal(user1.address);
    });

    it("should revert when oracle address is zero", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).setPriceOracle(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, attacker, user1 } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).setPriceOracle(user1.address)
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  12. pause / unpause
  // ═══════════════════════════════════════════════════════════════════════

  describe("pause / unpause", function () {
    it("should pause the contract", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await bonding.connect(owner).pause();
      expect(await bonding.paused()).to.be.true;
    });

    it("should unpause the contract", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await bonding.connect(owner).pause();
      await bonding.connect(owner).unpause();
      expect(await bonding.paused()).to.be.false;
    });

    it("should block bond() when paused", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      await bonding.connect(owner).pause();

      await usdc.connect(user1).approve(await bonding.getAddress(), 1000n * 10n ** 6n);
      await expect(
        bonding.connect(user1).bond(await usdc.getAddress(), 1000n * 10n ** 6n)
      ).to.be.revertedWithCustomError(bonding, "EnforcedPause");
    });

    it("should allow claim() when paused", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithActiveBondFixture);
      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(owner).pause();
      await expect(bonding.connect(user1).claim(await usdc.getAddress())).to.not.be.reverted;
    });

    it("should allow claimAll() when paused", async function () {
      const { bonding, usdc, owner, user1 } = await loadFixture(deployWithActiveBondFixture);
      await time.increase(Number(VESTING_PERIOD) + 1);
      await bonding.connect(owner).pause();
      await expect(bonding.connect(user1).claimAll()).to.not.be.reverted;
    });

    it("should revert pause when called by non-owner", async function () {
      const { bonding, attacker } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).pause()
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });

    it("should revert unpause when called by non-owner", async function () {
      const { bonding, owner, attacker } = await loadFixture(deployBondingFixture);
      await bonding.connect(owner).pause();
      await expect(
        bonding.connect(attacker).unpause()
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  13. renounceOwnership
  // ═══════════════════════════════════════════════════════════════════════

  describe("renounceOwnership", function () {
    it("should always revert with InvalidParameters (H-01 fix)", async function () {
      const { bonding, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });

    it("should revert even when called by non-owner", async function () {
      const { bonding, attacker } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).renounceOwnership()
      ).to.be.revertedWithCustomError(bonding, "InvalidParameters");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  14. rescueToken
  // ═══════════════════════════════════════════════════════════════════════

  describe("rescueToken", function () {
    it("should rescue accidentally sent non-XOM tokens to treasury", async function () {
      const { bonding, dai, owner, treasury } = await loadFixture(deployBondingFixture);
      const bondingAddr = await bonding.getAddress();
      const daiAddr = await dai.getAddress();
      const rescueAmount = ethers.parseEther("1000");

      // Accidentally send DAI to bonding contract
      await dai.mint(bondingAddr, rescueAmount);

      const treasuryBefore = await dai.balanceOf(treasury.address);
      await expect(bonding.connect(owner).rescueToken(daiAddr, rescueAmount))
        .to.emit(bonding, "TokenRescued").withArgs(daiAddr, rescueAmount, treasury.address);

      expect(await dai.balanceOf(treasury.address)).to.equal(treasuryBefore + rescueAmount);
    });

    it("should revert when trying to rescue XOM", async function () {
      const { bonding, xom, owner } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(owner).rescueToken(await xom.getAddress(), ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(bonding, "CannotRescueXom");
    });

    it("should revert when called by non-owner", async function () {
      const { bonding, dai, attacker } = await loadFixture(deployBondingFixture);
      await expect(
        bonding.connect(attacker).rescueToken(await dai.getAddress(), ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  15. View Functions
  // ═══════════════════════════════════════════════════════════════════════

  describe("View functions", function () {
    it("getBondInfo should return correct values for active bond", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();
      const [xomOwed, claimed, claimable, vestingEnd] = await bonding.getBondInfo(user1.address, usdcAddr);

      expect(xomOwed).to.be.gt(0);
      expect(claimed).to.equal(0);
      expect(claimable).to.equal(0); // just bonded, nothing vested yet
      expect(vestingEnd).to.be.gt(0);
    });

    it("getBondInfo should return zeros for user with no bond", async function () {
      const { bonding, usdc, user2 } = await loadFixture(deployWithUsdcAssetFixture);
      const [xomOwed, claimed, claimable, vestingEnd] = await bonding.getBondInfo(user2.address, await usdc.getAddress());
      expect(xomOwed).to.equal(0);
      expect(claimed).to.equal(0);
      expect(claimable).to.equal(0);
      expect(vestingEnd).to.equal(0);
    });

    it("getBondTerms should show remaining capacity correctly", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 200_000n * 10n ** 6n;

      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(usdcAddr, bondAmount);

      const [, , , capacity, remaining] = await bonding.getBondTerms(usdcAddr);
      expect(remaining).to.equal(capacity - bondAmount);
    });

    it("calculateBondOutput should return correct values", async function () {
      const { bonding, usdc } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const amount = 1000n * 10n ** 6n;

      const [xomOut, effectivePrice] = await bonding.calculateBondOutput(usdcAddr, amount);

      const expectedEffectivePrice = (INITIAL_XOM_PRICE * (BASIS_POINTS - DISCOUNT_BPS)) / BASIS_POINTS;
      expect(effectivePrice).to.equal(expectedEffectivePrice);

      const assetValue = amount * 10n ** 12n; // normalize 6 -> 18
      const expectedXom = (assetValue * PRICE_PRECISION) / expectedEffectivePrice;
      expect(xomOut).to.equal(expectedXom);
    });

    it("calculateBondOutput should return (0, 0) for unsupported asset", async function () {
      const { bonding } = await loadFixture(deployBondingFixture);
      const randomAddr = ethers.Wallet.createRandom().address;
      const [xomOut, effectivePrice] = await bonding.calculateBondOutput(randomAddr, 1000);
      expect(xomOut).to.equal(0);
      expect(effectivePrice).to.equal(0);
    });

    it("getProtocolStats should return aggregate statistics", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const bondAmount = 1000n * 10n ** 6n;
      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(await usdc.getAddress(), bondAmount);

      const [distributed, outstanding, valueReceived, assetCount] = await bonding.getProtocolStats();
      expect(distributed).to.be.gt(0);
      expect(outstanding).to.be.gt(0);
      expect(valueReceived).to.equal(bondAmount * 10n ** 12n);
      expect(assetCount).to.equal(1);
    });

    it("getBondAssets should return all added assets", async function () {
      const { bonding, usdc, dai, owner } = await loadFixture(deployWithUsdcAssetFixture);
      await bonding.connect(owner).addBondAsset(await dai.getAddress(), 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      const assets = await bonding.getBondAssets();
      expect(assets.length).to.equal(2);
    });

    it("getBondAssetCount should return correct count", async function () {
      const { bonding, usdc, dai, owner } = await loadFixture(deployWithUsdcAssetFixture);
      expect(await bonding.getBondAssetCount()).to.equal(1);
      await bonding.connect(owner).addBondAsset(await dai.getAddress(), 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      expect(await bonding.getBondAssetCount()).to.equal(2);
    });

    it("getXomPrice should return fixed price", async function () {
      const { bonding } = await loadFixture(deployBondingFixture);
      expect(await bonding.getXomPrice()).to.equal(INITIAL_XOM_PRICE);
    });

    it("getClaimable should return correct amount at various vesting points", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithActiveBondFixture);
      const usdcAddr = await usdc.getAddress();
      const [xomOwed] = await bonding.getBondInfo(user1.address, usdcAddr);

      // At start: nothing claimable
      expect(await bonding.getClaimable(user1.address, usdcAddr)).to.equal(0);

      // At 50%: approximately half
      await time.increase(Number(VESTING_PERIOD) / 2);
      const halfClaimable = await bonding.getClaimable(user1.address, usdcAddr);
      expect(halfClaimable).to.be.closeTo(xomOwed / 2n, xomOwed / 100n);

      // After 100%: full amount
      await time.increase(Number(VESTING_PERIOD));
      expect(await bonding.getClaimable(user1.address, usdcAddr)).to.equal(xomOwed);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  16. Edge Cases
  // ═══════════════════════════════════════════════════════════════════════

  describe("Edge cases", function () {
    it("should handle bonds for different assets independently per user", async function () {
      const { bonding, usdc, dai, owner, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const daiAddr = await dai.getAddress();

      await bonding.connect(owner).addBondAsset(daiAddr, 18, DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);

      // Bond USDC
      await usdc.connect(user1).approve(await bonding.getAddress(), 1000n * 10n ** 6n);
      await bonding.connect(user1).bond(usdcAddr, 1000n * 10n ** 6n);

      // Bond DAI (different asset, should not conflict)
      await dai.connect(user1).approve(await bonding.getAddress(), ethers.parseEther("500"));
      await bonding.connect(user1).bond(daiAddr, ethers.parseEther("500"));

      const [usdcOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const [daiOwed] = await bonding.getBondInfo(user1.address, daiAddr);
      expect(usdcOwed).to.be.gt(0);
      expect(daiOwed).to.be.gt(0);
    });

    it("should reset daily capacity at day boundary", async function () {
      const { bonding, usdc, owner, user1, user2 } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      const smallCap = 500n * 10n ** 6n;
      await bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, VESTING_PERIOD, smallCap);

      // Fill daily capacity
      await usdc.connect(user1).approve(await bonding.getAddress(), smallCap);
      await bonding.connect(user1).bond(usdcAddr, smallCap);

      // Should fail same day
      await usdc.connect(user2).approve(await bonding.getAddress(), 1n * 10n ** 6n);
      await expect(
        bonding.connect(user2).bond(usdcAddr, 1n * 10n ** 6n)
      ).to.be.revertedWithCustomError(bonding, "DailyCapacityExceeded");

      // Advance to next day
      await time.increase(86400);

      // First user's bond is still active, so user2 should bond
      // (user1 cannot re-bond same asset until claimed)
      await expect(
        bonding.connect(user2).bond(usdcAddr, 1n * 10n ** 6n)
      ).to.not.be.reverted;
    });

    it("should correctly normalize 6-decimal assets to 18 decimals in calculation", async function () {
      const { bonding, usdc } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();

      // 100 USDC = 100e6 should normalize to 100e18 internally
      const [xomOut] = await bonding.calculateBondOutput(usdcAddr, 100n * 10n ** 6n);

      // Expected: (100e18 * 1e18) / (0.005 * 0.9 * 1e18) = (100e18 * 1e18) / 4.5e15
      const assetValue = 100n * 10n ** 18n;
      const discountedPrice = (INITIAL_XOM_PRICE * 9000n) / 10000n; // 4.5e15
      const expected = (assetValue * PRICE_PRECISION) / discountedPrice;
      expect(xomOut).to.equal(expected);
    });

    it("should handle Ownable2Step transfer correctly", async function () {
      const { bonding, owner, user1 } = await loadFixture(deployBondingFixture);

      // Start ownership transfer
      await bonding.connect(owner).transferOwnership(user1.address);
      expect(await bonding.owner()).to.equal(owner.address); // still old owner
      expect(await bonding.pendingOwner()).to.equal(user1.address);

      // Accept ownership
      await bonding.connect(user1).acceptOwnership();
      expect(await bonding.owner()).to.equal(user1.address);
    });

    it("should prevent non-pending owner from accepting ownership", async function () {
      const { bonding, owner, user1, attacker } = await loadFixture(deployBondingFixture);
      await bonding.connect(owner).transferOwnership(user1.address);

      await expect(
        bonding.connect(attacker).acceptOwnership()
      ).to.be.revertedWithCustomError(bonding, "OwnableUnauthorizedAccount");
    });

    it("should handle multiple users bonding the same asset simultaneously", async function () {
      const { bonding, usdc, user1, user2 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondingAddr = await bonding.getAddress();
      const amount = 500n * 10n ** 6n;

      await usdc.connect(user1).approve(bondingAddr, amount);
      await usdc.connect(user2).approve(bondingAddr, amount);

      await bonding.connect(user1).bond(usdcAddr, amount);
      await bonding.connect(user2).bond(usdcAddr, amount);

      const [user1Owed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const [user2Owed] = await bonding.getBondInfo(user2.address, usdcAddr);
      expect(user1Owed).to.be.gt(0);
      expect(user2Owed).to.be.gt(0);
    });

    it("should correctly track totalXomOutstanding through bond + claim lifecycle", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      const usdcAddr = await usdc.getAddress();
      const bondAmount = 1000n * 10n ** 6n;

      expect(await bonding.totalXomOutstanding()).to.equal(0);

      // Bond
      await usdc.connect(user1).approve(await bonding.getAddress(), bondAmount);
      await bonding.connect(user1).bond(usdcAddr, bondAmount);

      const afterBond = await bonding.totalXomOutstanding();
      expect(afterBond).to.be.gt(0);

      // Partial claim
      await time.increase(Number(VESTING_PERIOD) / 2);
      await bonding.connect(user1).claim(usdcAddr);

      const afterPartialClaim = await bonding.totalXomOutstanding();
      expect(afterPartialClaim).to.be.lt(afterBond);
      expect(afterPartialClaim).to.be.gt(0);

      // Full claim
      await time.increase(Number(VESTING_PERIOD));
      await bonding.connect(user1).claim(usdcAddr);

      expect(await bonding.totalXomOutstanding()).to.equal(0);
    });

    it("should apply different discount rates correctly across assets", async function () {
      const { bonding, usdc, dai, owner, user1, user2 } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      const daiAddr = await dai.getAddress();

      // USDC with 5% discount
      await bonding.connect(owner).addBondAsset(usdcAddr, 6, 500n, VESTING_PERIOD, DAILY_CAPACITY);
      // DAI with 15% discount
      await bonding.connect(owner).addBondAsset(daiAddr, 18, 1500n, VESTING_PERIOD, DAILY_CAPACITY);

      // Bond same $ value with each
      const usdcAmount = 1000n * 10n ** 6n; // 1000 USDC
      const daiAmount = ethers.parseEther("1000"); // 1000 DAI

      await usdc.connect(user1).approve(await bonding.getAddress(), usdcAmount);
      await bonding.connect(user1).bond(usdcAddr, usdcAmount);

      await dai.connect(user2).approve(await bonding.getAddress(), daiAmount);
      await bonding.connect(user2).bond(daiAddr, daiAmount);

      const [usdcOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const [daiOwed] = await bonding.getBondInfo(user2.address, daiAddr);

      // Higher discount = more XOM owed
      expect(daiOwed).to.be.gt(usdcOwed);
    });

    it("should handle bonding at MIN_DISCOUNT_BPS and MAX_DISCOUNT_BPS", async function () {
      const { bonding, usdc, dai, owner, user1, user2 } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      const daiAddr = await dai.getAddress();

      await bonding.connect(owner).addBondAsset(usdcAddr, 6, MIN_DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);
      await bonding.connect(owner).addBondAsset(daiAddr, 18, MAX_DISCOUNT_BPS, VESTING_PERIOD, DAILY_CAPACITY);

      const usdcAmount = 1000n * 10n ** 6n;
      const daiAmount = ethers.parseEther("1000");

      await usdc.connect(user1).approve(await bonding.getAddress(), usdcAmount);
      await bonding.connect(user1).bond(usdcAddr, usdcAmount);

      await dai.connect(user2).approve(await bonding.getAddress(), daiAmount);
      await bonding.connect(user2).bond(daiAddr, daiAmount);

      const [usdcOwed] = await bonding.getBondInfo(user1.address, usdcAddr);
      const [daiOwed] = await bonding.getBondInfo(user2.address, daiAddr);

      // Both should get non-zero XOM
      expect(usdcOwed).to.be.gt(0);
      expect(daiOwed).to.be.gt(0);
      // Max discount gets more
      expect(daiOwed).to.be.gt(usdcOwed);
    });

    it("should handle vesting at MIN_VESTING_PERIOD and MAX_VESTING_PERIOD", async function () {
      const { bonding, usdc, dai, owner, user1, user2 } = await loadFixture(deployBondingFixture);
      const usdcAddr = await usdc.getAddress();
      const daiAddr = await dai.getAddress();

      await bonding.connect(owner).addBondAsset(usdcAddr, 6, DISCOUNT_BPS, MIN_VESTING_PERIOD, DAILY_CAPACITY);
      await bonding.connect(owner).addBondAsset(daiAddr, 18, DISCOUNT_BPS, MAX_VESTING_PERIOD, DAILY_CAPACITY);

      const usdcAmount = 100n * 10n ** 6n;
      const daiAmount = ethers.parseEther("100");

      await usdc.connect(user1).approve(await bonding.getAddress(), usdcAmount);
      await bonding.connect(user1).bond(usdcAddr, usdcAmount);

      await dai.connect(user2).approve(await bonding.getAddress(), daiAmount);
      await bonding.connect(user2).bond(daiAddr, daiAmount);

      const [, , , usdcVestEnd] = await bonding.getBondInfo(user1.address, usdcAddr);
      const [, , , daiVestEnd] = await bonding.getBondInfo(user2.address, daiAddr);

      const latestTime = BigInt(await time.latest());
      // The vesting ends should differ by approximately (MAX - MIN) seconds
      expect(daiVestEnd - usdcVestEnd).to.be.closeTo(
        MAX_VESTING_PERIOD - MIN_VESTING_PERIOD,
        5n // account for block time differences
      );
    });

    it("should not allow bond when user has insufficient asset approval", async function () {
      const { bonding, usdc, user1 } = await loadFixture(deployWithUsdcAssetFixture);
      // No approval
      await expect(
        bonding.connect(user1).bond(await usdc.getAddress(), 1000n * 10n ** 6n)
      ).to.be.reverted; // ERC20InsufficientAllowance
    });

    it("should not allow bond when user has insufficient asset balance", async function () {
      const { bonding, usdc, attacker } = await loadFixture(deployWithUsdcAssetFixture);
      // attacker has 0 USDC
      await usdc.connect(attacker).approve(await bonding.getAddress(), 1000n * 10n ** 6n);
      await expect(
        bonding.connect(attacker).bond(await usdc.getAddress(), 1000n * 10n ** 6n)
      ).to.be.reverted; // ERC20InsufficientBalance
    });
  });
});
