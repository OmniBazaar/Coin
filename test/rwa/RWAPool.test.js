const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title RWAPool Test Suite
 * @notice Tests for the constant-product AMM liquidity pool used by the RWA DEX.
 * @dev Validates factory initialization, reserve tracking, LP token minting
 *      (including MINIMUM_LIQUIDITY lock on first deposit), burning, and
 *      the ERC-20 LP token metadata.
 */
describe("RWAPool", function () {
  let deployer;
  let user;
  let other;
  let pool;
  let tokenA;
  let tokenB;

  const MINIMUM_LIQUIDITY = 1000n;

  before(async function () {
    const signers = await ethers.getSigners();
    deployer = signers[0];
    user = signers[1];
    other = signers[2];
  });

  beforeEach(async function () {
    // Deploy two MockERC20 tokens (2-arg constructor: name, symbol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    tokenA = await MockERC20.deploy("Token A", "TKA");
    await tokenA.waitForDeployment();
    tokenB = await MockERC20.deploy("Token B", "TKB");
    await tokenB.waitForDeployment();

    // Mint supply to deployer for distribution
    await tokenA.mint(deployer.address, ethers.parseEther("1000000"));
    await tokenB.mint(deployer.address, ethers.parseEther("1000000"));

    // Deploy the pool (deployer becomes factory)
    const Pool = await ethers.getContractFactory("RWAPool");
    pool = await Pool.deploy();
    await pool.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should set factory to the deployer address", async function () {
      expect(await pool.factory()).to.equal(deployer.address);
    });

    it("should set LP token name to 'RWA Pool LP Token'", async function () {
      expect(await pool.name()).to.equal("RWA Pool LP Token");
    });

    it("should set LP token symbol to 'RWA-LP'", async function () {
      expect(await pool.symbol()).to.equal("RWA-LP");
    });
  });

  // ---------------------------------------------------------------------------
  // initialize
  // ---------------------------------------------------------------------------

  describe("initialize", function () {
    it("should set token0 and token1 when called by the factory", async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );

      expect(await pool.token0()).to.equal(await tokenA.getAddress());
      expect(await pool.token1()).to.equal(await tokenB.getAddress());
    });

    it("should revert with NotFactory when called by a non-factory address", async function () {
      await expect(
        pool.connect(user).initialize(
          await tokenA.getAddress(),
          await tokenB.getAddress()
        )
      ).to.be.revertedWithCustomError(pool, "NotFactory");
    });

    it("should revert with AlreadyInitialized on a second call", async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );

      await expect(
        pool.initialize(
          await tokenA.getAddress(),
          await tokenB.getAddress()
        )
      ).to.be.revertedWithCustomError(pool, "AlreadyInitialized");
    });
  });

  // ---------------------------------------------------------------------------
  // MINIMUM_LIQUIDITY
  // ---------------------------------------------------------------------------

  describe("MINIMUM_LIQUIDITY", function () {
    it("should equal 1000", async function () {
      expect(await pool.MINIMUM_LIQUIDITY()).to.equal(MINIMUM_LIQUIDITY);
    });
  });

  // ---------------------------------------------------------------------------
  // getReserves
  // ---------------------------------------------------------------------------

  describe("getReserves", function () {
    it("should return zeros before any liquidity is added", async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );

      const [reserve0, reserve1, timestamp] = await pool.getReserves();
      expect(reserve0).to.equal(0);
      expect(reserve1).to.equal(0);
      expect(timestamp).to.equal(0);
    });
  });

  // ---------------------------------------------------------------------------
  // mint (add liquidity)
  // ---------------------------------------------------------------------------

  describe("mint", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("100");

    beforeEach(async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );
    });

    it("should mint LP tokens on first deposit and lock MINIMUM_LIQUIDITY", async function () {
      const poolAddress = await pool.getAddress();
      const deadAddress = "0x000000000000000000000000000000000000dEaD";

      // Transfer tokens to the pool (the Uniswap V2 pattern)
      await tokenA.transfer(poolAddress, depositA);
      await tokenB.transfer(poolAddress, depositB);

      // Mint LP tokens to user
      await pool.mint(user.address);

      // sqrt(100e18 * 100e18) = 100e18; minus MINIMUM_LIQUIDITY (1000) sent to dead address
      const expectedLiquidity = ethers.parseEther("100") - MINIMUM_LIQUIDITY;

      expect(await pool.balanceOf(user.address)).to.equal(expectedLiquidity);
      expect(await pool.balanceOf(deadAddress)).to.equal(MINIMUM_LIQUIDITY);

      // Reserves should reflect the deposited amounts
      const [reserve0, reserve1] = await pool.getReserves();
      expect(reserve0).to.equal(depositA);
      expect(reserve1).to.equal(depositB);
    });

    it("should emit a Mint event with the deposited amounts", async function () {
      const poolAddress = await pool.getAddress();

      await tokenA.transfer(poolAddress, depositA);
      await tokenB.transfer(poolAddress, depositB);

      await expect(pool.mint(user.address))
        .to.emit(pool, "Mint")
        .withArgs(deployer.address, depositA, depositB);
    });
  });

  // ---------------------------------------------------------------------------
  // burn (remove liquidity)
  // ---------------------------------------------------------------------------

  describe("burn", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("100");

    beforeEach(async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );

      const poolAddress = await pool.getAddress();

      // First, provide liquidity
      await tokenA.transfer(poolAddress, depositA);
      await tokenB.transfer(poolAddress, depositB);
      await pool.mint(user.address);
    });

    it("should burn LP tokens and return underlying tokens", async function () {
      const poolAddress = await pool.getAddress();
      const liquidity = await pool.balanceOf(user.address);

      // Transfer LP tokens to the pool (Uniswap V2 burn pattern)
      await pool.connect(user).transfer(poolAddress, liquidity);

      const balanceABefore = await tokenA.balanceOf(other.address);
      const balanceBBefore = await tokenB.balanceOf(other.address);

      // Burn and send underlying to `other`
      await pool.burn(other.address);

      const balanceAAfter = await tokenA.balanceOf(other.address);
      const balanceBAfter = await tokenB.balanceOf(other.address);

      // User should have received some of both tokens
      expect(balanceAAfter).to.be.gt(balanceABefore);
      expect(balanceBAfter).to.be.gt(balanceBBefore);

      // Reserves should have decreased
      const [reserve0, reserve1] = await pool.getReserves();
      expect(reserve0).to.be.lt(depositA);
      expect(reserve1).to.be.lt(depositB);
    });

    it("should emit a Burn event", async function () {
      const poolAddress = await pool.getAddress();
      const liquidity = await pool.balanceOf(user.address);

      await pool.connect(user).transfer(poolAddress, liquidity);

      await expect(pool.burn(other.address)).to.emit(pool, "Burn");
    });
  });
});
