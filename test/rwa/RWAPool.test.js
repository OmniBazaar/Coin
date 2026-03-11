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

  // ---------------------------------------------------------------------------
  // Helper: Initialize pool and add initial liquidity
  // ---------------------------------------------------------------------------

  /**
   * @notice Shared setup: initialize the pool, deposit equal amounts, mint LP.
   * @param {bigint} amountA Deposit for tokenA
   * @param {bigint} amountB Deposit for tokenB
   * @param {object} recipient Signer receiving LP tokens
   */
  async function initializeAndDeposit(amountA, amountB, recipient) {
    await pool.initialize(
      await tokenA.getAddress(),
      await tokenB.getAddress()
    );
    const poolAddress = await pool.getAddress();
    await tokenA.transfer(poolAddress, amountA);
    await tokenB.transfer(poolAddress, amountB);
    await pool.mint(recipient.address);
  }

  // ---------------------------------------------------------------------------
  // swap — constant-product formula
  // ---------------------------------------------------------------------------

  describe("swap", function () {
    const depositA = ethers.parseEther("1000");
    const depositB = ethers.parseEther("1000");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should execute a token0-for-token1 swap preserving k", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("10");

      // Calculate expected output: dy = (y * dx) / (x + dx)
      const [r0Before, r1Before] = await pool.getReserves();
      const expectedOut = (r1Before * swapIn) / (r0Before + swapIn);

      // Send token0 into pool, request token1 out
      await tokenA.transfer(poolAddress, swapIn);
      await pool.swap(0, expectedOut, other.address, "0x");

      const [r0After, r1After] = await pool.getReserves();

      // K must not decrease
      expect(r0After * r1After).to.be.gte(r0Before * r1Before);

      // Recipient received token1
      expect(await tokenB.balanceOf(other.address)).to.equal(expectedOut);
    });

    it("should execute a token1-for-token0 swap preserving k", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("10");

      const [r0Before, r1Before] = await pool.getReserves();
      const expectedOut = (r0Before * swapIn) / (r1Before + swapIn);

      // Send token1 into pool, request token0 out
      await tokenB.transfer(poolAddress, swapIn);
      await pool.swap(expectedOut, 0, other.address, "0x");

      const [r0After, r1After] = await pool.getReserves();
      expect(r0After * r1After).to.be.gte(r0Before * r1Before);
      expect(await tokenA.balanceOf(other.address)).to.equal(expectedOut);
    });

    it("should revert with KValueDecreased when output exceeds constant-product", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("10");

      const [r0, r1] = await pool.getReserves();
      // Calculate correct output then add 1 wei to violate k
      const correctOut = (r1 * swapIn) / (r0 + swapIn);
      const excessiveOut = correctOut + 1n;

      await tokenA.transfer(poolAddress, swapIn);
      await expect(
        pool.swap(0, excessiveOut, other.address, "0x")
      ).to.be.revertedWithCustomError(pool, "KValueDecreased");
    });

    it("should revert with InsufficientOutputAmount when both outputs are zero", async function () {
      await expect(
        pool.swap(0, 0, other.address, "0x")
      ).to.be.revertedWithCustomError(pool, "InsufficientOutputAmount");
    });

    it("should revert with InsufficientInputAmount when no input tokens are provided", async function () {
      // Request output without sending any input tokens
      await expect(
        pool.swap(0, ethers.parseEther("1"), other.address, "0x")
      ).to.be.revertedWithCustomError(pool, "InsufficientInputAmount");
    });

    it("should revert with InsufficientLiquidity when output exceeds reserves", async function () {
      const tooMuch = depositA + 1n;
      await expect(
        pool.swap(tooMuch, 0, other.address, "0x")
      ).to.be.revertedWithCustomError(pool, "InsufficientLiquidity");
    });

    it("should revert with InsufficientLiquidity when output equals reserves", async function () {
      // Strict less-than check: amount0Out < reserve0
      await expect(
        pool.swap(depositA, 0, other.address, "0x")
      ).to.be.revertedWithCustomError(pool, "InsufficientLiquidity");
    });

    it("should revert with InvalidRecipient when swapping to address(0)", async function () {
      const poolAddress = await pool.getAddress();
      await tokenA.transfer(poolAddress, ethers.parseEther("1"));
      await expect(
        pool.swap(0, ethers.parseEther("0.5"), ethers.ZeroAddress, "0x")
      ).to.be.revertedWithCustomError(pool, "InvalidRecipient");
    });

    it("should revert with InvalidRecipient when swapping to token0 address", async function () {
      const poolAddress = await pool.getAddress();
      const token0Addr = await tokenA.getAddress();
      await tokenA.transfer(poolAddress, ethers.parseEther("1"));
      await expect(
        pool.swap(0, ethers.parseEther("0.5"), token0Addr, "0x")
      ).to.be.revertedWithCustomError(pool, "InvalidRecipient");
    });

    it("should revert with InvalidRecipient when swapping to token1 address", async function () {
      const poolAddress = await pool.getAddress();
      const token1Addr = await tokenB.getAddress();
      await tokenA.transfer(poolAddress, ethers.parseEther("1"));
      await expect(
        pool.swap(0, ethers.parseEther("0.5"), token1Addr, "0x")
      ).to.be.revertedWithCustomError(pool, "InvalidRecipient");
    });

    it("should revert with NotFactory when swap is called by non-factory", async function () {
      await expect(
        pool.connect(user).swap(0, ethers.parseEther("1"), other.address, "0x")
      ).to.be.revertedWithCustomError(pool, "NotFactory");
    });
  });

  // ---------------------------------------------------------------------------
  // swap — flash swap disabled (audit fix H-02)
  // ---------------------------------------------------------------------------

  describe("swap — flash swaps disabled", function () {
    const depositA = ethers.parseEther("1000");
    const depositB = ethers.parseEther("1000");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should revert with FlashSwapsDisabled when data is non-empty", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("10");
      const [r0, r1] = await pool.getReserves();
      const amountOut = (r1 * swapIn) / (r0 + swapIn);

      await tokenA.transfer(poolAddress, swapIn);

      // Pass non-empty calldata to trigger flash swap path
      await expect(
        pool.swap(0, amountOut, other.address, "0x01")
      ).to.be.revertedWithCustomError(pool, "FlashSwapsDisabled");
    });
  });

  // ---------------------------------------------------------------------------
  // swap — events
  // ---------------------------------------------------------------------------

  describe("swap — Swap and Sync events", function () {
    const depositA = ethers.parseEther("1000");
    const depositB = ethers.parseEther("1000");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should emit a Swap event with correct input/output amounts", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("10");
      const [r0, r1] = await pool.getReserves();
      const amountOut = (r1 * swapIn) / (r0 + swapIn);

      await tokenA.transfer(poolAddress, swapIn);

      await expect(pool.swap(0, amountOut, other.address, "0x"))
        .to.emit(pool, "Swap")
        .withArgs(
          deployer.address,  // sender (factory)
          swapIn,            // amount0In
          0,                 // amount1In
          0,                 // amount0Out
          amountOut,         // amount1Out
          other.address      // to
        );
    });

    it("should emit a Sync event after swap with updated reserves", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("10");
      const [r0, r1] = await pool.getReserves();
      const amountOut = (r1 * swapIn) / (r0 + swapIn);

      await tokenA.transfer(poolAddress, swapIn);

      await expect(pool.swap(0, amountOut, other.address, "0x"))
        .to.emit(pool, "Sync")
        .withArgs(r0 + swapIn, r1 - amountOut);
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple deposits — proportional LP minting
  // ---------------------------------------------------------------------------

  describe("mint — proportional LP minting on subsequent deposits", function () {
    const initialA = ethers.parseEther("100");
    const initialB = ethers.parseEther("200");

    beforeEach(async function () {
      await initializeAndDeposit(initialA, initialB, user);
    });

    it("should mint LP tokens proportional to smallest ratio on second deposit", async function () {
      const poolAddress = await pool.getAddress();
      const totalSupplyBefore = await pool.totalSupply();
      const [r0, r1] = await pool.getReserves();

      // Deposit 50% more in correct ratio
      const addA = initialA / 2n;
      const addB = initialB / 2n;

      await tokenA.transfer(poolAddress, addA);
      await tokenB.transfer(poolAddress, addB);
      await pool.mint(other.address);

      const otherLP = await pool.balanceOf(other.address);

      // Expected: min( (addA * totalSupply) / r0, (addB * totalSupply) / r1 )
      const lp0 = (addA * totalSupplyBefore) / r0;
      const lp1 = (addB * totalSupplyBefore) / r1;
      const expectedLP = lp0 < lp1 ? lp0 : lp1;

      expect(otherLP).to.equal(expectedLP);
    });

    it("should use the minimum ratio when deposit is imbalanced", async function () {
      const poolAddress = await pool.getAddress();
      const totalSupplyBefore = await pool.totalSupply();
      const [r0, r1] = await pool.getReserves();

      // Deposit imbalanced: lots of A, little of B
      const addA = ethers.parseEther("50");
      const addB = ethers.parseEther("10"); // Less than proportional

      await tokenA.transfer(poolAddress, addA);
      await tokenB.transfer(poolAddress, addB);
      await pool.mint(other.address);

      const otherLP = await pool.balanceOf(other.address);

      // LP is min of the two ratios, so B dominates
      const lp0 = (addA * totalSupplyBefore) / r0;
      const lp1 = (addB * totalSupplyBefore) / r1;
      const expectedLP = lp0 < lp1 ? lp0 : lp1;

      expect(otherLP).to.equal(expectedLP);
      // Confirm B-side is the binding constraint
      expect(lp1).to.be.lt(lp0);
    });

    it("should revert with InsufficientLiquidityMinted when added amounts are zero", async function () {
      // Mint without transferring any tokens produces zero liquidity
      await expect(
        pool.mint(other.address)
      ).to.be.revertedWithCustomError(pool, "InsufficientLiquidityMinted");
    });

    it("should not allow non-factory to mint", async function () {
      await expect(
        pool.connect(user).mint(other.address)
      ).to.be.revertedWithCustomError(pool, "NotFactory");
    });
  });

  // ---------------------------------------------------------------------------
  // mint — initial deposit validation
  // ---------------------------------------------------------------------------

  describe("mint — initial deposit validation", function () {
    beforeEach(async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );
    });

    it("should revert with InitialDepositTooSmall for tiny first deposit", async function () {
      const poolAddress = await pool.getAddress();
      // MINIMUM_INITIAL_DEPOSIT = 10_000
      // sqrt(100 * 100) = 100 < 10_000 => too small
      await tokenA.transfer(poolAddress, 100n);
      await tokenB.transfer(poolAddress, 100n);

      await expect(
        pool.mint(user.address)
      ).to.be.revertedWithCustomError(pool, "InitialDepositTooSmall");
    });

    it("should succeed when sqrt product exactly meets MINIMUM_INITIAL_DEPOSIT", async function () {
      const poolAddress = await pool.getAddress();
      // sqrt(10_000 * 10_000) = 10_000 >= MINIMUM_INITIAL_DEPOSIT
      await tokenA.transfer(poolAddress, 10_000n);
      await tokenB.transfer(poolAddress, 10_000n);

      await pool.mint(user.address);
      // LP = 10_000 - 1000 = 9_000
      expect(await pool.balanceOf(user.address)).to.equal(9000n);
    });
  });

  // ---------------------------------------------------------------------------
  // burn — edge cases
  // ---------------------------------------------------------------------------

  describe("burn — edge cases", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("100");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should revert with InsufficientLiquidityBurned when zero LP is in pool", async function () {
      // Do NOT transfer any LP tokens to pool before calling burn
      await expect(
        pool.burn(other.address)
      ).to.be.revertedWithCustomError(pool, "InsufficientLiquidityBurned");
    });

    it("should revert with InvalidRecipient when burning to address(0)", async function () {
      const poolAddress = await pool.getAddress();
      const liquidity = await pool.balanceOf(user.address);
      await pool.connect(user).transfer(poolAddress, liquidity);

      await expect(
        pool.burn(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(pool, "InvalidRecipient");
    });

    it("should revert with InvalidRecipient when burning to pool itself", async function () {
      const poolAddress = await pool.getAddress();
      const liquidity = await pool.balanceOf(user.address);
      await pool.connect(user).transfer(poolAddress, liquidity);

      await expect(
        pool.burn(poolAddress)
      ).to.be.revertedWithCustomError(pool, "InvalidRecipient");
    });

    it("should not allow non-factory to burn", async function () {
      await expect(
        pool.connect(user).burn(other.address)
      ).to.be.revertedWithCustomError(pool, "NotFactory");
    });

    it("should return correct proportional amounts on partial burn", async function () {
      const poolAddress = await pool.getAddress();
      const totalLP = await pool.balanceOf(user.address);

      // Burn half the LP tokens
      const halfLP = totalLP / 2n;
      await pool.connect(user).transfer(poolAddress, halfLP);

      const balanceABefore = await tokenA.balanceOf(other.address);
      const balanceBBefore = await tokenB.balanceOf(other.address);

      await pool.burn(other.address);

      const balanceAAfter = await tokenA.balanceOf(other.address);
      const balanceBAfter = await tokenB.balanceOf(other.address);

      const receivedA = balanceAAfter - balanceABefore;
      const receivedB = balanceBAfter - balanceBBefore;

      // Should receive roughly half the reserves (minus the locked minimum)
      // Total supply = totalLP + MINIMUM_LIQUIDITY
      const totalSupply = totalLP + MINIMUM_LIQUIDITY;
      const expectedA = (halfLP * depositA) / totalSupply;
      const expectedB = (halfLP * depositB) / totalSupply;

      expect(receivedA).to.equal(expectedA);
      expect(receivedB).to.equal(expectedB);
    });

    it("should emit Burn event with correct amounts and recipient", async function () {
      const poolAddress = await pool.getAddress();
      const liquidity = await pool.balanceOf(user.address);
      const totalSupply = await pool.totalSupply();

      await pool.connect(user).transfer(poolAddress, liquidity);

      const balance0 = await tokenA.balanceOf(poolAddress);
      const balance1 = await tokenB.balanceOf(poolAddress);
      const expectedA = (liquidity * balance0) / totalSupply;
      const expectedB = (liquidity * balance1) / totalSupply;

      await expect(pool.burn(other.address))
        .to.emit(pool, "Burn")
        .withArgs(deployer.address, expectedA, expectedB, other.address);
    });
  });

  // ---------------------------------------------------------------------------
  // kLast tracking
  // ---------------------------------------------------------------------------

  describe("kLast tracking", function () {
    const depositA = ethers.parseEther("500");
    const depositB = ethers.parseEther("500");

    it("should update kLast after mint", async function () {
      await initializeAndDeposit(depositA, depositB, user);

      const kLast = await pool.kLast();
      expect(kLast).to.equal(depositA * depositB);
    });

    it("should update kLast after burn", async function () {
      await initializeAndDeposit(depositA, depositB, user);
      const poolAddress = await pool.getAddress();

      const halfLP = (await pool.balanceOf(user.address)) / 2n;
      await pool.connect(user).transfer(poolAddress, halfLP);
      await pool.burn(other.address);

      const [r0, r1] = await pool.getReserves();
      const kLast = await pool.kLast();
      expect(kLast).to.equal(r0 * r1);
    });
  });

  // ---------------------------------------------------------------------------
  // sync — reserve synchronization
  // ---------------------------------------------------------------------------

  describe("sync", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("100");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should update reserves to match actual token balances", async function () {
      const poolAddress = await pool.getAddress();

      // Donate tokens directly (not via mint)
      const donation = ethers.parseEther("50");
      await tokenA.transfer(poolAddress, donation);

      // Reserves are stale before sync
      const [r0Before] = await pool.getReserves();
      expect(r0Before).to.equal(depositA);

      await pool.sync();

      const [r0After, r1After] = await pool.getReserves();
      expect(r0After).to.equal(depositA + donation);
      expect(r1After).to.equal(depositB);
    });

    it("should emit Sync event with updated reserves", async function () {
      const poolAddress = await pool.getAddress();
      const donation = ethers.parseEther("25");
      await tokenA.transfer(poolAddress, donation);

      await expect(pool.sync())
        .to.emit(pool, "Sync")
        .withArgs(depositA + donation, depositB);
    });

    it("should be callable by anyone (not restricted to factory)", async function () {
      // sync() is permissionless by design
      await expect(pool.connect(user).sync()).to.not.be.reverted;
    });

    it("should revert with SyncRateLimited when called twice in same block", async function () {
      // Disable auto-mine so both transactions land in the same block.
      await ethers.provider.send("evm_setAutomine", [false]);

      try {
        // Build raw transaction calldata for sync()
        const poolAddress = await pool.getAddress();
        const syncData = pool.interface.encodeFunctionData("sync");

        // Send both transactions via eth_sendTransaction to avoid
        // ethers.js hanging on revert decoding in manual-mine mode.
        const tx1Hash = await ethers.provider.send("eth_sendTransaction", [{
          from: deployer.address,
          to: poolAddress,
          data: syncData,
          gas: "0x100000"
        }]);

        const tx2Hash = await ethers.provider.send("eth_sendTransaction", [{
          from: user.address,
          to: poolAddress,
          data: syncData,
          gas: "0x100000"
        }]);

        // Mine a single block containing both transactions
        await ethers.provider.send("evm_mine", []);

        // Fetch receipts
        const receipt1 = await ethers.provider.send(
          "eth_getTransactionReceipt", [tx1Hash]
        );
        const receipt2 = await ethers.provider.send(
          "eth_getTransactionReceipt", [tx2Hash]
        );

        // First sync() should succeed (status 0x1)
        expect(receipt1.status).to.equal("0x1");
        // Second sync() should revert with SyncRateLimited (status 0x0)
        expect(receipt2.status).to.equal("0x0");
      } finally {
        // Always re-enable auto-mine so subsequent tests are unaffected
        await ethers.provider.send("evm_setAutomine", [true]);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // skim — excess token recovery
  // ---------------------------------------------------------------------------

  describe("skim", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("100");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should transfer excess token0 to recipient", async function () {
      const poolAddress = await pool.getAddress();
      const excess = ethers.parseEther("10");
      await tokenA.transfer(poolAddress, excess);

      const balanceBefore = await tokenA.balanceOf(other.address);
      await pool.skim(other.address);
      const balanceAfter = await tokenA.balanceOf(other.address);

      expect(balanceAfter - balanceBefore).to.equal(excess);
    });

    it("should transfer excess token1 to recipient", async function () {
      const poolAddress = await pool.getAddress();
      const excess = ethers.parseEther("7");
      await tokenB.transfer(poolAddress, excess);

      const balanceBefore = await tokenB.balanceOf(other.address);
      await pool.skim(other.address);
      const balanceAfter = await tokenB.balanceOf(other.address);

      expect(balanceAfter - balanceBefore).to.equal(excess);
    });

    it("should transfer zero when there is no excess", async function () {
      const balanceABefore = await tokenA.balanceOf(other.address);
      const balanceBBefore = await tokenB.balanceOf(other.address);

      await pool.skim(other.address);

      expect(await tokenA.balanceOf(other.address)).to.equal(balanceABefore);
      expect(await tokenB.balanceOf(other.address)).to.equal(balanceBBefore);
    });

    it("should revert with InvalidRecipient when skimming to address(0)", async function () {
      await expect(
        pool.skim(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(pool, "InvalidRecipient");
    });

    it("should revert with NotFactory when called by non-factory", async function () {
      await expect(
        pool.connect(user).skim(other.address)
      ).to.be.revertedWithCustomError(pool, "NotFactory");
    });
  });

  // ---------------------------------------------------------------------------
  // TWAP / cumulative price oracles
  // ---------------------------------------------------------------------------

  describe("cumulative price oracles", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("200");

    it("should start at zero before any liquidity", async function () {
      await pool.initialize(
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );

      expect(await pool.price0CumulativeLast()).to.equal(0);
      expect(await pool.price1CumulativeLast()).to.equal(0);
    });

    it("should accumulate price after time passes and a reserve update", async function () {
      await initializeAndDeposit(depositA, depositB, user);

      // Cumulative prices are zero right after first mint (no time elapsed)
      const p0After = await pool.price0CumulativeLast();
      const p1After = await pool.price1CumulativeLast();

      // Advance time
      await ethers.provider.send("evm_increaseTime", [100]);
      await ethers.provider.send("evm_mine", []);

      // Trigger an update (sync is permissionless)
      await pool.sync();

      const p0Updated = await pool.price0CumulativeLast();
      const p1Updated = await pool.price1CumulativeLast();

      // After time elapsed, cumulative prices should increase
      expect(p0Updated).to.be.gt(p0After);
      expect(p1Updated).to.be.gt(p1After);
    });
  });

  // ---------------------------------------------------------------------------
  // Large swap edge cases
  // ---------------------------------------------------------------------------

  describe("large and dust amount edge cases", function () {
    it("should handle a swap that drains nearly all of one reserve", async function () {
      const depositA = ethers.parseEther("1000");
      const depositB = ethers.parseEther("1000");
      await initializeAndDeposit(depositA, depositB, user);

      const poolAddress = await pool.getAddress();

      // Swap a large amount of token0 in to drain most of token1
      const largeIn = ethers.parseEther("99000"); // 99x the reserve
      await tokenA.mint(deployer.address, largeIn);
      await tokenA.transfer(poolAddress, largeIn);

      const [r0, r1] = await pool.getReserves();
      // dy = (r1 * largeIn) / (r0 + largeIn) -- nearly all of r1
      const amountOut = (r1 * largeIn) / (r0 + largeIn);

      await pool.swap(0, amountOut, other.address, "0x");

      const [r0After, r1After] = await pool.getReserves();
      // token1 reserve should be very small
      expect(r1After).to.be.lt(ethers.parseEther("11"));
      // k still holds
      expect(r0After * r1After).to.be.gte(r0 * r1);
    });

    it("should handle asymmetric initial deposit (different amounts)", async function () {
      const amtA = ethers.parseEther("1");
      const amtB = ethers.parseEther("10000");
      await initializeAndDeposit(amtA, amtB, user);

      const lp = await pool.balanceOf(user.address);
      // sqrt(1e18 * 10000e18) = sqrt(1e40) = 1e20 = 100 ether
      const expected = ethers.parseEther("100") - MINIMUM_LIQUIDITY;
      expect(lp).to.equal(expected);
    });
  });

  // ---------------------------------------------------------------------------
  // MINIMUM_INITIAL_DEPOSIT constant
  // ---------------------------------------------------------------------------

  describe("MINIMUM_INITIAL_DEPOSIT", function () {
    it("should equal 10000", async function () {
      expect(await pool.MINIMUM_INITIAL_DEPOSIT()).to.equal(10_000n);
    });
  });

  // ---------------------------------------------------------------------------
  // getReserves after operations
  // ---------------------------------------------------------------------------

  describe("getReserves after operations", function () {
    const depositA = ethers.parseEther("500");
    const depositB = ethers.parseEther("500");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should reflect updated reserves after a swap", async function () {
      const poolAddress = await pool.getAddress();
      const swapIn = ethers.parseEther("50");

      const [r0, r1] = await pool.getReserves();
      const amountOut = (r1 * swapIn) / (r0 + swapIn);

      await tokenA.transfer(poolAddress, swapIn);
      await pool.swap(0, amountOut, other.address, "0x");

      const [r0After, r1After] = await pool.getReserves();
      expect(r0After).to.equal(r0 + swapIn);
      expect(r1After).to.equal(r1 - amountOut);
    });

    it("should have a non-zero blockTimestampLast after deposit", async function () {
      const [, , timestamp] = await pool.getReserves();
      expect(timestamp).to.be.gt(0);
    });
  });

  // ---------------------------------------------------------------------------
  // ERC20 LP token behaviour
  // ---------------------------------------------------------------------------

  describe("LP token ERC20 behaviour", function () {
    const depositA = ethers.parseEther("100");
    const depositB = ethers.parseEther("100");

    beforeEach(async function () {
      await initializeAndDeposit(depositA, depositB, user);
    });

    it("should have 18 decimals", async function () {
      expect(await pool.decimals()).to.equal(18);
    });

    it("should allow LP token transfers between users", async function () {
      const amount = ethers.parseEther("10");
      await pool.connect(user).transfer(other.address, amount);
      expect(await pool.balanceOf(other.address)).to.equal(amount);
    });

    it("should allow approve and transferFrom", async function () {
      const amount = ethers.parseEther("5");
      await pool.connect(user).approve(other.address, amount);
      await pool.connect(other).transferFrom(
        user.address, other.address, amount
      );
      expect(await pool.balanceOf(other.address)).to.equal(amount);
    });

    it("should track totalSupply correctly as MINIMUM_LIQUIDITY + user LP", async function () {
      const userLP = await pool.balanceOf(user.address);
      const totalSupply = await pool.totalSupply();
      expect(totalSupply).to.equal(userLP + MINIMUM_LIQUIDITY);
    });
  });
});
