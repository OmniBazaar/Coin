const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniSwapRouter Test Suite
 * @notice Comprehensive tests for the multi-hop DEX swap router with fee
 *         collection, slippage protection, and MEV-protection deadlines.
 * @dev Validates:
 *   1.  Constructor parameter guards
 *   2.  swap() — single-hop, multi-hop (2 & 3 hops), fee deduction,
 *       slippage, deadline, path validation, zero-input, same-token,
 *       zero-recipient, unregistered source, paused state
 *   3.  addLiquiditySource / removeLiquiditySource
 *   4.  setSwapFee / proposeFeeVault + acceptFeeVault (48h timelock)
 *   5.  rescueTokens
 *   6.  getQuote — estimation, fee math, path validation
 *   7.  getSwapStats — volume & fee tracking
 *   8.  renounceOwnership — always reverts
 *   9.  Ownable2Step — transferOwnership + acceptOwnership
 *   10. Pausable — swap blocked when paused
 *
 * Uses:
 *   - contracts/test/MockERC20.sol  (2-arg constructor, public mint)
 *   - contracts/mocks/MockSwapAdapter.sol (configurable exchange rate)
 */
describe("OmniSwapRouter", function () {
  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  /** @dev 30 bps = 0.30% default fee */
  const DEFAULT_FEE_BPS = 30;
  const BASIS_POINTS_DIVISOR = 10_000n;
  const SWAP_AMOUNT = ethers.parseEther("1000");
  const ONE_ETH = ethers.parseEther("1");

  /** @dev 1:1 exchange rate (1e18) */
  const RATE_1_TO_1 = ethers.parseEther("1");
  /** @dev 1:2 exchange rate (2e18) — double output */
  const RATE_1_TO_2 = ethers.parseEther("2");
  /** @dev 1:0.5 exchange rate (0.5e18) — half output */
  const RATE_1_TO_HALF = ethers.parseEther("0.5");

  // ---------------------------------------------------------------------------
  // Fixture
  // ---------------------------------------------------------------------------

  /**
   * Deploy fresh instances of MockERC20 tokens, MockSwapAdapter, and
   * OmniSwapRouter before each test group.
   */
  async function deployRouterFixture() {
    const signers = await ethers.getSigners();
    const [owner, feeVault, user, other, newOwner] = signers;

    // Deploy mock tokens (MockERC20 from contracts/test/)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const tokenA = await MockERC20.deploy("Token A", "TKA");
    const tokenB = await MockERC20.deploy("Token B", "TKB");
    const tokenC = await MockERC20.deploy("Token C", "TKC");
    const tokenD = await MockERC20.deploy("Token D", "TKD");
    const rescueToken = await MockERC20.deploy("Rescue Token", "RSC");

    // Deploy mock swap adapter (1:1 rate)
    const MockSwapAdapter = await ethers.getContractFactory("MockSwapAdapter");
    const adapter = await MockSwapAdapter.deploy(RATE_1_TO_1);
    const adapter2 = await MockSwapAdapter.deploy(RATE_1_TO_2);
    const adapterHalf = await MockSwapAdapter.deploy(RATE_1_TO_HALF);

    // Deploy OmniSwapRouter
    const OmniSwapRouter = await ethers.getContractFactory("OmniSwapRouter");
    const router = await OmniSwapRouter.deploy(
      feeVault.address,
      DEFAULT_FEE_BPS,
      ethers.ZeroAddress // no trusted forwarder
    );

    // Register the adapter as a liquidity source
    const sourceId = ethers.id("MOCK_DEX");
    const sourceId2 = ethers.id("MOCK_DEX_2");
    const sourceIdHalf = ethers.id("MOCK_DEX_HALF");
    await router.connect(owner).addLiquiditySource(sourceId, adapter.target);
    await router.connect(owner).addLiquiditySource(sourceId2, adapter2.target);
    await router.connect(owner).addLiquiditySource(sourceIdHalf, adapterHalf.target);

    // Mint tokens to the user
    await tokenA.mint(user.address, ethers.parseEther("100000"));
    await tokenB.mint(user.address, ethers.parseEther("100000"));

    // Approve the router to spend user's tokenA
    await tokenA.connect(user).approve(router.target, ethers.MaxUint256);
    await tokenB.connect(user).approve(router.target, ethers.MaxUint256);

    // Helper: compute a far-future deadline from the current block timestamp
    async function futureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    return {
      router,
      tokenA,
      tokenB,
      tokenC,
      tokenD,
      rescueToken,
      adapter,
      adapter2,
      adapterHalf,
      sourceId,
      sourceId2,
      sourceIdHalf,
      owner,
      feeVault,
      user,
      other,
      newOwner,
      futureDeadline,
      OmniSwapRouter,
      MockSwapAdapter,
      MockERC20,
    };
  }

  // ===========================================================================
  // 1. Constructor
  // ===========================================================================

  describe("Constructor", function () {
    it("Should deploy with valid feeVault and swapFeeBps", async function () {
      const { router, feeVault } = await loadFixture(deployRouterFixture);
      expect(router.target).to.be.properAddress;
      expect(await router.feeVault()).to.equal(feeVault.address);
      expect(await router.swapFeeBps()).to.equal(DEFAULT_FEE_BPS);
    });

    it("Should revert with InvalidRecipientAddress when feeVault is zero", async function () {
      const { OmniSwapRouter } = await loadFixture(deployRouterFixture);
      await expect(
        OmniSwapRouter.deploy(ethers.ZeroAddress, DEFAULT_FEE_BPS, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        { interface: OmniSwapRouter.interface },
        "InvalidRecipientAddress"
      );
    });

    it("Should revert with FeeTooHigh when swapFeeBps exceeds 100", async function () {
      const { OmniSwapRouter, feeVault } = await loadFixture(deployRouterFixture);
      await expect(
        OmniSwapRouter.deploy(feeVault.address, 101, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        { interface: OmniSwapRouter.interface },
        "FeeTooHigh"
      );
    });

    it("Should accept swapFeeBps of exactly 100 (1%)", async function () {
      const { OmniSwapRouter, feeVault } = await loadFixture(deployRouterFixture);
      const r = await OmniSwapRouter.deploy(feeVault.address, 100, ethers.ZeroAddress);
      expect(await r.swapFeeBps()).to.equal(100);
    });

    it("Should accept swapFeeBps of 0 (no fee)", async function () {
      const { OmniSwapRouter, feeVault } = await loadFixture(deployRouterFixture);
      const r = await OmniSwapRouter.deploy(feeVault.address, 0, ethers.ZeroAddress);
      expect(await r.swapFeeBps()).to.equal(0);
    });

    it("Should set the deployer as owner", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);
      expect(await router.owner()).to.equal(owner.address);
    });
  });

  // ===========================================================================
  // 2. swap()
  // ===========================================================================

  describe("swap", function () {
    // -------------------------------------------------------------------------
    // Single-hop success
    // -------------------------------------------------------------------------

    it("Should execute a single-hop swap and transfer output to recipient", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const recipientBalBefore = await tokenB.balanceOf(other.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const recipientBalAfter = await tokenB.balanceOf(other.address);
      expect(recipientBalAfter).to.be.gt(recipientBalBefore);
    });

    it("Should deduct swap fee from input and send to feeVault", async function () {
      const { router, tokenA, tokenB, sourceId, user, feeVault, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const feeVaultBalBefore = await tokenA.balanceOf(feeVault.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const feeVaultBalAfter = await tokenA.balanceOf(feeVault.address);
      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      expect(feeVaultBalAfter - feeVaultBalBefore).to.equal(expectedFee);
    });

    it("Should emit SwapExecuted event with correct parameters", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.emit(router, "SwapExecuted");
    });

    it("Should return correct SwapResult struct", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      const swapAmount = SWAP_AMOUNT - expectedFee;

      // Static call to get the return value
      const result = await router.connect(user).swap.staticCall({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      expect(result.amountOut).to.equal(swapAmount); // 1:1 adapter
      expect(result.feeAmount).to.equal(expectedFee);
      expect(result.route).to.not.equal(ethers.ZeroHash);
    });

    it("Should transfer user tokenIn to the router during swap", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const userBalBefore = await tokenA.balanceOf(user.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const userBalAfter = await tokenA.balanceOf(user.address);
      expect(userBalBefore - userBalAfter).to.equal(SWAP_AMOUNT);
    });

    it("Should leave no tokenOut balance stuck in the router after swap", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      expect(await tokenB.balanceOf(router.target)).to.equal(0);
    });

    // -------------------------------------------------------------------------
    // Multi-hop (2 hops)
    // -------------------------------------------------------------------------

    it("Should execute a 2-hop swap (A -> B -> C)", async function () {
      const { router, tokenA, tokenB, tokenC, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenC.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target, tokenC.target],
        sources: [sourceId, sourceId],
        deadline,
        recipient: other.address,
      });

      const recipientBal = await tokenC.balanceOf(other.address);
      expect(recipientBal).to.be.gt(0);
    });

    // -------------------------------------------------------------------------
    // Multi-hop (3 hops, MAX_HOPS)
    // -------------------------------------------------------------------------

    it("Should execute a 3-hop swap (A -> B -> C -> D)", async function () {
      const { router, tokenA, tokenB, tokenC, tokenD, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenD.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target, tokenC.target, tokenD.target],
        sources: [sourceId, sourceId, sourceId],
        deadline,
        recipient: other.address,
      });

      const recipientBal = await tokenD.balanceOf(other.address);
      expect(recipientBal).to.be.gt(0);
    });

    it("Should correctly chain exchange rates across multiple hops", async function () {
      const { router, tokenA, tokenB, tokenC, sourceId, sourceId2, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      // Hop 1: 1:1 (sourceId), Hop 2: 1:2 (sourceId2)
      // After fee: SWAP_AMOUNT * (10000 - 30) / 10000 = 997 eth
      // After hop1 (1:1): 997 eth
      // After hop2 (1:2): 1994 eth
      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      const afterFee = SWAP_AMOUNT - expectedFee;
      const expectedOutput = afterFee * 2n; // hop2 doubles

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenC.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target, tokenC.target],
        sources: [sourceId, sourceId2],
        deadline,
        recipient: other.address,
      });

      const recipientBal = await tokenC.balanceOf(other.address);
      expect(recipientBal).to.equal(expectedOutput);
    });

    // -------------------------------------------------------------------------
    // Fee deduction
    // -------------------------------------------------------------------------

    it("Should calculate fee correctly at 30 bps (0.30%)", async function () {
      const { router, tokenA, tokenB, sourceId, user, feeVault, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const expectedFee = (SWAP_AMOUNT * 30n) / BASIS_POINTS_DIVISOR;

      const result = await router.connect(user).swap.staticCall({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      expect(result.feeAmount).to.equal(expectedFee);
    });

    it("Should skip fee transfer when swapFeeBps is 0", async function () {
      const { OmniSwapRouter, tokenA, tokenB, sourceId, user, feeVault, other, owner, futureDeadline, MockSwapAdapter } =
        await loadFixture(deployRouterFixture);

      // Deploy a zero-fee router
      const zeroFeeRouter = await OmniSwapRouter.deploy(feeVault.address, 0, ethers.ZeroAddress);
      const adapter = await MockSwapAdapter.deploy(RATE_1_TO_1);
      await zeroFeeRouter.connect(owner).addLiquiditySource(sourceId, adapter.target);
      await tokenA.mint(user.address, SWAP_AMOUNT);
      await tokenA.connect(user).approve(zeroFeeRouter.target, ethers.MaxUint256);

      const deadline = await futureDeadline();
      const feeVaultBalBefore = await tokenA.balanceOf(feeVault.address);

      await zeroFeeRouter.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const feeVaultBalAfter = await tokenA.balanceOf(feeVault.address);
      expect(feeVaultBalAfter - feeVaultBalBefore).to.equal(0);
    });

    // -------------------------------------------------------------------------
    // Slippage protection
    // -------------------------------------------------------------------------

    it("Should revert with InsufficientOutputAmount when output below minAmountOut", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      // With 30 bps fee and 1:1 rate, output = 997 ether
      // Set minAmountOut higher than possible output
      const tooHighMin = ethers.parseEther("999");

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: tooHighMin,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InsufficientOutputAmount");
    });

    it("Should succeed when output equals minAmountOut exactly", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      const exactOutput = SWAP_AMOUNT - expectedFee; // 1:1 adapter

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: exactOutput,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.not.be.reverted;
    });

    // -------------------------------------------------------------------------
    // Deadline enforcement
    // -------------------------------------------------------------------------

    it("Should revert with SwapDeadlineExpired when deadline is in the past", async function () {
      const { router, tokenA, tokenB, sourceId, user, other } =
        await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline: 1, // far in the past
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "SwapDeadlineExpired");
    });

    it("Should revert with SwapDeadlineExpired when deadline equals current timestamp", async function () {
      const { router, tokenA, tokenB, sourceId, user, other } =
        await loadFixture(deployRouterFixture);

      const block = await ethers.provider.getBlock("latest");
      // block.timestamp is the timestamp of the latest mined block.
      // The next block will have timestamp > block.timestamp.
      // So using block.timestamp as deadline means it will be expired.
      const currentTimestamp = block.timestamp;

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline: currentTimestamp,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "SwapDeadlineExpired");
    });

    // -------------------------------------------------------------------------
    // Path validation
    // -------------------------------------------------------------------------

    it("Should revert with EmptyPath when path is empty", async function () {
      const { router, tokenA, tokenB, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [],
          sources: [],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "EmptyPath");
    });

    it("Should revert with PathTooLong when path has more than MAX_HOPS + 1 elements", async function () {
      const { router, tokenA, tokenB, tokenC, tokenD, sourceId, user, other, futureDeadline, MockERC20 } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const tokenE = await MockERC20.deploy("Token E", "TKE");

      // 5 elements = 4 hops, MAX_HOPS = 3
      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenE.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target, tokenC.target, tokenD.target, tokenE.target],
          sources: [sourceId, sourceId, sourceId, sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "PathTooLong");
    });

    it("Should revert with PathMismatch when path[0] != tokenIn", async function () {
      const { router, tokenA, tokenB, tokenC, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenC.target, tokenB.target], // path[0] != tokenIn
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "PathMismatch");
    });

    it("Should revert with PathMismatch when path[last] != tokenOut", async function () {
      const { router, tokenA, tokenB, tokenC, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenC.target], // path[last] != tokenOut
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "PathMismatch");
    });

    it("Should revert with InvalidLiquiditySource when sources count != path.length - 1", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      // 2 elements in path means 1 hop, but providing 2 sources
      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId, sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InvalidLiquiditySource");
    });

    // -------------------------------------------------------------------------
    // Zero input
    // -------------------------------------------------------------------------

    it("Should revert with ZeroInputAmount when amountIn is zero", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: 0,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "ZeroInputAmount");
    });

    // -------------------------------------------------------------------------
    // Same token in/out
    // -------------------------------------------------------------------------

    it("Should revert with InvalidTokenAddress when tokenIn == tokenOut", async function () {
      const { router, tokenA, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenA.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenA.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InvalidTokenAddress");
    });

    // -------------------------------------------------------------------------
    // Zero token addresses
    // -------------------------------------------------------------------------

    it("Should revert with InvalidTokenAddress when tokenIn is zero address", async function () {
      const { router, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: ethers.ZeroAddress,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [ethers.ZeroAddress, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InvalidTokenAddress");
    });

    it("Should revert with InvalidTokenAddress when tokenOut is zero address", async function () {
      const { router, tokenA, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: ethers.ZeroAddress,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, ethers.ZeroAddress],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InvalidTokenAddress");
    });

    // -------------------------------------------------------------------------
    // Zero recipient
    // -------------------------------------------------------------------------

    it("Should revert with InvalidRecipientAddress when recipient is zero", async function () {
      const { router, tokenA, tokenB, sourceId, user, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: ethers.ZeroAddress,
        })
      ).to.be.revertedWithCustomError(router, "InvalidRecipientAddress");
    });

    // -------------------------------------------------------------------------
    // Unregistered liquidity source
    // -------------------------------------------------------------------------

    it("Should revert with InvalidLiquiditySource when source is not registered", async function () {
      const { router, tokenA, tokenB, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const unknownSource = ethers.id("UNKNOWN_DEX");

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [unknownSource],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InvalidLiquiditySource");
    });

    // -------------------------------------------------------------------------
    // Paused
    // -------------------------------------------------------------------------

    it("Should revert with EnforcedPause when contract is paused", async function () {
      const { router, tokenA, tokenB, sourceId, user, owner, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      await router.connect(owner).pause();
      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "EnforcedPause");
    });

    it("Should allow swap after unpause", async function () {
      const { router, tokenA, tokenB, sourceId, user, owner, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      await router.connect(owner).pause();
      await router.connect(owner).unpause();
      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.not.be.reverted;
    });

    // -------------------------------------------------------------------------
    // User can be own recipient
    // -------------------------------------------------------------------------

    it("Should allow user to be the swap recipient", async function () {
      const { router, tokenA, tokenB, sourceId, user, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const userBBalBefore = await tokenB.balanceOf(user.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: user.address,
      });

      const userBBalAfter = await tokenB.balanceOf(user.address);
      expect(userBBalAfter).to.be.gt(userBBalBefore);
    });
  });

  // ===========================================================================
  // 3. addLiquiditySource
  // ===========================================================================

  describe("addLiquiditySource", function () {
    it("Should register a new liquidity source adapter", async function () {
      const { router, owner, MockSwapAdapter } = await loadFixture(deployRouterFixture);

      const newAdapter = await MockSwapAdapter.deploy(RATE_1_TO_1);
      const newSourceId = ethers.id("NEW_DEX");

      await router.connect(owner).addLiquiditySource(newSourceId, newAdapter.target);

      expect(await router.liquiditySources(newSourceId)).to.equal(newAdapter.target);
    });

    it("Should emit LiquiditySourceAdded event", async function () {
      const { router, owner, MockSwapAdapter } = await loadFixture(deployRouterFixture);

      const newAdapter = await MockSwapAdapter.deploy(RATE_1_TO_1);
      const newSourceId = ethers.id("NEW_DEX_2");

      await expect(
        router.connect(owner).addLiquiditySource(newSourceId, newAdapter.target)
      )
        .to.emit(router, "LiquiditySourceAdded")
        .withArgs(newSourceId, newAdapter.target);
    });

    it("Should revert with InvalidTokenAddress when adapter is zero address", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      const newSourceId = ethers.id("ZERO_ADAPTER");

      await expect(
        router.connect(owner).addLiquiditySource(newSourceId, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(router, "InvalidTokenAddress");
    });

    it("Should revert with AdapterNotContract when adapter is an EOA (no code)", async function () {
      const { router, owner, other } = await loadFixture(deployRouterFixture);

      const newSourceId = ethers.id("EOA_ADAPTER");

      await expect(
        router.connect(owner).addLiquiditySource(newSourceId, other.address)
      ).to.be.revertedWithCustomError(router, "AdapterNotContract");
    });

    it("Should revert with OwnableUnauthorizedAccount when called by non-owner", async function () {
      const { router, user, MockSwapAdapter } = await loadFixture(deployRouterFixture);

      const newAdapter = await MockSwapAdapter.deploy(RATE_1_TO_1);
      const newSourceId = ethers.id("UNAUTH_DEX");

      await expect(
        router.connect(user).addLiquiditySource(newSourceId, newAdapter.target)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should allow overwriting an existing source with a new adapter", async function () {
      const { router, owner, sourceId, MockSwapAdapter } = await loadFixture(deployRouterFixture);

      const newAdapter = await MockSwapAdapter.deploy(RATE_1_TO_2);
      await router.connect(owner).addLiquiditySource(sourceId, newAdapter.target);

      expect(await router.liquiditySources(sourceId)).to.equal(newAdapter.target);
    });
  });

  // ===========================================================================
  // 4. removeLiquiditySource
  // ===========================================================================

  describe("removeLiquiditySource", function () {
    it("Should remove a registered liquidity source", async function () {
      const { router, owner, sourceId } = await loadFixture(deployRouterFixture);

      await router.connect(owner).removeLiquiditySource(sourceId);

      expect(await router.liquiditySources(sourceId)).to.equal(ethers.ZeroAddress);
    });

    it("Should emit LiquiditySourceRemoved event", async function () {
      const { router, owner, sourceId } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(owner).removeLiquiditySource(sourceId)
      )
        .to.emit(router, "LiquiditySourceRemoved")
        .withArgs(sourceId);
    });

    it("Should revert with OwnableUnauthorizedAccount when called by non-owner", async function () {
      const { router, user, sourceId } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).removeLiquiditySource(sourceId)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should succeed silently when removing a non-existent source", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      const nonExistentSource = ethers.id("NON_EXISTENT");

      await expect(
        router.connect(owner).removeLiquiditySource(nonExistentSource)
      ).to.not.be.reverted;
    });

    it("Should cause swaps through removed source to revert", async function () {
      const { router, tokenA, tokenB, sourceId, user, owner, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      await router.connect(owner).removeLiquiditySource(sourceId);
      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "InvalidLiquiditySource");
    });
  });

  // ===========================================================================
  // 5. setSwapFee
  // ===========================================================================

  describe("setSwapFee", function () {
    it("Should update swapFeeBps", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).setSwapFee(50);
      expect(await router.swapFeeBps()).to.equal(50);
    });

    it("Should emit SwapFeeUpdated event with old and new values", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await expect(router.connect(owner).setSwapFee(50))
        .to.emit(router, "SwapFeeUpdated")
        .withArgs(DEFAULT_FEE_BPS, 50);
    });

    it("Should accept fee of exactly 100 bps (1%)", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).setSwapFee(100);
      expect(await router.swapFeeBps()).to.equal(100);
    });

    it("Should accept fee of 0 (no fee)", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).setSwapFee(0);
      expect(await router.swapFeeBps()).to.equal(0);
    });

    it("Should revert with FeeTooHigh when fee exceeds 100 bps", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(owner).setSwapFee(101)
      ).to.be.revertedWithCustomError(router, "FeeTooHigh");
    });

    it("Should revert with OwnableUnauthorizedAccount when called by non-owner", async function () {
      const { router, user } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).setSwapFee(50)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should apply new fee to subsequent swaps", async function () {
      const { router, tokenA, tokenB, sourceId, user, owner, feeVault, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      // Change fee to 100 bps (1%)
      await router.connect(owner).setSwapFee(100);
      const deadline = await futureDeadline();

      const feeVaultBalBefore = await tokenA.balanceOf(feeVault.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const feeVaultBalAfter = await tokenA.balanceOf(feeVault.address);
      const expectedFee = (SWAP_AMOUNT * 100n) / BASIS_POINTS_DIVISOR;
      expect(feeVaultBalAfter - feeVaultBalBefore).to.equal(expectedFee);
    });
  });

  // ===========================================================================
  // 6. proposeFeeVault / acceptFeeVault (48h timelock)
  // ===========================================================================

  describe("proposeFeeVault / acceptFeeVault", function () {
    /** @dev 48 hours in seconds — matches FEE_VAULT_DELAY in contract */
    const FEE_VAULT_DELAY = 48 * 3600;

    it("Should update feeVault after propose + timelock + accept", async function () {
      const { router, owner, other } = await loadFixture(deployRouterFixture);

      await router.connect(owner).proposeFeeVault(other.address);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);
      await router.connect(owner).acceptFeeVault();

      expect(await router.feeVault()).to.equal(other.address);
    });

    it("Should emit FeeVaultChangeProposed event on propose", async function () {
      const { router, owner, other } = await loadFixture(deployRouterFixture);

      await expect(router.connect(owner).proposeFeeVault(other.address))
        .to.emit(router, "FeeVaultChangeProposed");
    });

    it("Should emit FeeVaultChangeAccepted event on accept", async function () {
      const { router, owner, feeVault, other } = await loadFixture(deployRouterFixture);

      await router.connect(owner).proposeFeeVault(other.address);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);

      await expect(router.connect(owner).acceptFeeVault())
        .to.emit(router, "FeeVaultChangeAccepted")
        .withArgs(feeVault.address, other.address);
    });

    it("Should revert with InvalidRecipientAddress when proposing zero address", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(owner).proposeFeeVault(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(router, "InvalidRecipientAddress");
    });

    it("Should revert with OwnableUnauthorizedAccount when proposeFeeVault called by non-owner", async function () {
      const { router, user, other } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).proposeFeeVault(other.address)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should revert with FeeVaultTimelockActive when accepting before timelock elapses", async function () {
      const { router, owner, other } = await loadFixture(deployRouterFixture);

      await router.connect(owner).proposeFeeVault(other.address);
      // Only advance 1 hour — not enough
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        router.connect(owner).acceptFeeVault()
      ).to.be.revertedWithCustomError(router, "FeeVaultTimelockActive");
    });

    it("Should revert with NoFeeVaultChangePending when accepting without a proposal", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(owner).acceptFeeVault()
      ).to.be.revertedWithCustomError(router, "NoFeeVaultChangePending");
    });

    it("Should direct fees to the new recipient after propose + accept", async function () {
      const { router, tokenA, tokenB, sourceId, user, owner, other, newOwner, futureDeadline } =
        await loadFixture(deployRouterFixture);

      await router.connect(owner).proposeFeeVault(newOwner.address);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);
      await router.connect(owner).acceptFeeVault();

      const deadline = await futureDeadline();
      const newRecipientBalBefore = await tokenA.balanceOf(newOwner.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const newRecipientBalAfter = await tokenA.balanceOf(newOwner.address);
      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      expect(newRecipientBalAfter - newRecipientBalBefore).to.equal(expectedFee);
    });
  });

  // ===========================================================================
  // 7. rescueTokens
  // ===========================================================================

  describe("rescueTokens", function () {
    it("Should rescue accidentally-sent tokens to feeVault", async function () {
      const { router, rescueToken, owner, feeVault } = await loadFixture(deployRouterFixture);

      const rescueAmount = ethers.parseEther("500");
      await rescueToken.mint(router.target, rescueAmount);

      const recipientBalBefore = await rescueToken.balanceOf(feeVault.address);
      await router.connect(owner).rescueTokens(rescueToken.target);
      const recipientBalAfter = await rescueToken.balanceOf(feeVault.address);

      expect(recipientBalAfter - recipientBalBefore).to.equal(rescueAmount);
    });

    it("Should emit TokensRescued event", async function () {
      const { router, rescueToken, owner } = await loadFixture(deployRouterFixture);

      const rescueAmount = ethers.parseEther("100");
      await rescueToken.mint(router.target, rescueAmount);

      await expect(router.connect(owner).rescueTokens(rescueToken.target))
        .to.emit(router, "TokensRescued")
        .withArgs(rescueToken.target, rescueAmount);
    });

    it("Should succeed silently when router has zero balance of the token", async function () {
      const { router, rescueToken, owner, feeVault } = await loadFixture(deployRouterFixture);

      const recipientBalBefore = await rescueToken.balanceOf(feeVault.address);
      await router.connect(owner).rescueTokens(rescueToken.target);
      const recipientBalAfter = await rescueToken.balanceOf(feeVault.address);

      expect(recipientBalAfter).to.equal(recipientBalBefore);
    });

    it("Should not emit TokensRescued when balance is zero", async function () {
      const { router, rescueToken, owner } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(owner).rescueTokens(rescueToken.target)
      ).to.not.emit(router, "TokensRescued");
    });

    it("Should revert with OwnableUnauthorizedAccount when called by non-owner", async function () {
      const { router, rescueToken, user } = await loadFixture(deployRouterFixture);

      await rescueToken.mint(router.target, ethers.parseEther("50"));

      await expect(
        router.connect(user).rescueTokens(rescueToken.target)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should leave zero balance in router after rescue", async function () {
      const { router, rescueToken, owner } = await loadFixture(deployRouterFixture);

      await rescueToken.mint(router.target, ethers.parseEther("999"));
      await router.connect(owner).rescueTokens(rescueToken.target);

      expect(await rescueToken.balanceOf(router.target)).to.equal(0);
    });
  });

  // ===========================================================================
  // 8. getQuote
  // ===========================================================================

  describe("getQuote", function () {
    it("Should return correct estimated output for single-hop quote", async function () {
      const { router, tokenA, tokenB, sourceId } = await loadFixture(deployRouterFixture);

      const [amountOut, feeAmount] = await router.getQuote(
        tokenA.target,
        tokenB.target,
        SWAP_AMOUNT,
        [tokenA.target, tokenB.target],
        [sourceId]
      );

      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      const expectedOutput = SWAP_AMOUNT - expectedFee; // 1:1 adapter
      expect(amountOut).to.equal(expectedOutput);
      expect(feeAmount).to.equal(expectedFee);
    });

    it("Should return correct estimated output for multi-hop quote", async function () {
      const { router, tokenA, tokenB, tokenC, sourceId, sourceId2 } =
        await loadFixture(deployRouterFixture);

      const [amountOut, feeAmount] = await router.getQuote(
        tokenA.target,
        tokenC.target,
        SWAP_AMOUNT,
        [tokenA.target, tokenB.target, tokenC.target],
        [sourceId, sourceId2] // 1:1, then 1:2
      );

      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      const afterFee = SWAP_AMOUNT - expectedFee;
      const expectedOutput = afterFee * 2n; // hop2 doubles
      expect(amountOut).to.equal(expectedOutput);
      expect(feeAmount).to.equal(expectedFee);
    });

    it("Should calculate fee correctly in quote", async function () {
      const { router, tokenA, tokenB, sourceId } = await loadFixture(deployRouterFixture);

      const amount = ethers.parseEther("10000");
      const [, feeAmount] = await router.getQuote(
        tokenA.target,
        tokenB.target,
        amount,
        [tokenA.target, tokenB.target],
        [sourceId]
      );

      const expectedFee = (amount * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      expect(feeAmount).to.equal(expectedFee);
    });

    it("Should revert with ZeroInputAmount when amountIn is zero", async function () {
      const { router, tokenA, tokenB, sourceId } = await loadFixture(deployRouterFixture);

      await expect(
        router.getQuote(
          tokenA.target,
          tokenB.target,
          0,
          [tokenA.target, tokenB.target],
          [sourceId]
        )
      ).to.be.revertedWithCustomError(router, "ZeroInputAmount");
    });

    it("Should revert with EmptyPath when path is empty", async function () {
      const { router, tokenA, tokenB } = await loadFixture(deployRouterFixture);

      await expect(
        router.getQuote(tokenA.target, tokenB.target, SWAP_AMOUNT, [], [])
      ).to.be.revertedWithCustomError(router, "EmptyPath");
    });

    it("Should revert with PathTooLong when path exceeds MAX_HOPS + 1", async function () {
      const { router, tokenA, tokenB, tokenC, tokenD, sourceId, MockERC20 } =
        await loadFixture(deployRouterFixture);

      const tokenE = await MockERC20.deploy("Token E", "TKE");

      await expect(
        router.getQuote(
          tokenA.target,
          tokenE.target,
          SWAP_AMOUNT,
          [tokenA.target, tokenB.target, tokenC.target, tokenD.target, tokenE.target],
          [sourceId, sourceId, sourceId, sourceId]
        )
      ).to.be.revertedWithCustomError(router, "PathTooLong");
    });

    it("Should revert with InvalidTokenAddress when tokenIn is zero", async function () {
      const { router, tokenB, sourceId } = await loadFixture(deployRouterFixture);

      await expect(
        router.getQuote(
          ethers.ZeroAddress,
          tokenB.target,
          SWAP_AMOUNT,
          [ethers.ZeroAddress, tokenB.target],
          [sourceId]
        )
      ).to.be.revertedWithCustomError(router, "InvalidTokenAddress");
    });

    it("Should revert with InvalidTokenAddress when tokenOut is zero", async function () {
      const { router, tokenA, sourceId } = await loadFixture(deployRouterFixture);

      await expect(
        router.getQuote(
          tokenA.target,
          ethers.ZeroAddress,
          SWAP_AMOUNT,
          [tokenA.target, ethers.ZeroAddress],
          [sourceId]
        )
      ).to.be.revertedWithCustomError(router, "InvalidTokenAddress");
    });

    it("Should revert with InvalidLiquiditySource when source is unregistered", async function () {
      const { router, tokenA, tokenB } = await loadFixture(deployRouterFixture);

      const unknownSource = ethers.id("UNKNOWN");

      await expect(
        router.getQuote(
          tokenA.target,
          tokenB.target,
          SWAP_AMOUNT,
          [tokenA.target, tokenB.target],
          [unknownSource]
        )
      ).to.be.revertedWithCustomError(router, "InvalidLiquiditySource");
    });
  });

  // ===========================================================================
  // 9. getSwapStats
  // ===========================================================================

  describe("getSwapStats", function () {
    it("Should return zero volume and fees initially", async function () {
      const { router } = await loadFixture(deployRouterFixture);

      const [volume, fees] = await router.getSwapStats();
      expect(volume).to.equal(0);
      expect(fees).to.equal(0);
    });

    it("Should track cumulative swap volume", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      // Swap 1
      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      // Swap 2
      const secondAmount = ethers.parseEther("500");
      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: secondAmount,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const [volume] = await router.getSwapStats();
      expect(volume).to.equal(SWAP_AMOUNT + secondAmount);
    });

    it("Should track cumulative fees collected", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const amount1 = ethers.parseEther("1000");
      const amount2 = ethers.parseEther("2000");

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: amount1,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: amount2,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const expectedFees =
        ((amount1 + amount2) * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;

      const [, fees] = await router.getSwapStats();
      expect(fees).to.equal(expectedFees);
    });
  });

  // ===========================================================================
  // 10. renounceOwnership
  // ===========================================================================

  describe("renounceOwnership", function () {
    it("Should always revert with InvalidRecipientAddress", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(router, "InvalidRecipientAddress");
    });

    it("Should revert even when called by the current owner", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      // Confirm owner is correct
      expect(await router.owner()).to.equal(owner.address);

      await expect(
        router.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(router, "InvalidRecipientAddress");
    });

    it("Should revert when called by a non-owner", async function () {
      const { router, user } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).renounceOwnership()
      ).to.be.revertedWithCustomError(router, "InvalidRecipientAddress");
    });
  });

  // ===========================================================================
  // 11. Ownable2Step
  // ===========================================================================

  describe("Ownable2Step", function () {
    it("Should allow owner to initiate ownership transfer", async function () {
      const { router, owner, newOwner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).transferOwnership(newOwner.address);
      expect(await router.pendingOwner()).to.equal(newOwner.address);
      // Owner should still be the original owner until accepted
      expect(await router.owner()).to.equal(owner.address);
    });

    it("Should allow pending owner to accept ownership", async function () {
      const { router, owner, newOwner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).transferOwnership(newOwner.address);
      await router.connect(newOwner).acceptOwnership();

      expect(await router.owner()).to.equal(newOwner.address);
      expect(await router.pendingOwner()).to.equal(ethers.ZeroAddress);
    });

    it("Should prevent non-pending-owner from accepting ownership", async function () {
      const { router, owner, newOwner, other } = await loadFixture(deployRouterFixture);

      await router.connect(owner).transferOwnership(newOwner.address);

      await expect(
        router.connect(other).acceptOwnership()
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should revert transferOwnership when called by non-owner", async function () {
      const { router, user, newOwner } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).transferOwnership(newOwner.address)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should allow new owner to manage contract after transfer", async function () {
      const { router, owner, newOwner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).transferOwnership(newOwner.address);
      await router.connect(newOwner).acceptOwnership();

      // New owner should be able to set fee
      await expect(router.connect(newOwner).setSwapFee(50)).to.not.be.reverted;
    });

    it("Should prevent old owner from managing contract after transfer", async function () {
      const { router, owner, newOwner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).transferOwnership(newOwner.address);
      await router.connect(newOwner).acceptOwnership();

      await expect(
        router.connect(owner).setSwapFee(50)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });
  });

  // ===========================================================================
  // 12. pause / unpause
  // ===========================================================================

  describe("pause / unpause", function () {
    it("Should allow owner to pause", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).pause();
      expect(await router.paused()).to.equal(true);
    });

    it("Should allow owner to unpause", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).pause();
      await router.connect(owner).unpause();
      expect(await router.paused()).to.equal(false);
    });

    it("Should revert pause when called by non-owner", async function () {
      const { router, user } = await loadFixture(deployRouterFixture);

      await expect(
        router.connect(user).pause()
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should revert unpause when called by non-owner", async function () {
      const { router, owner, user } = await loadFixture(deployRouterFixture);

      await router.connect(owner).pause();

      await expect(
        router.connect(user).unpause()
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("Should block swap when paused but allow admin functions", async function () {
      const { router, owner } = await loadFixture(deployRouterFixture);

      await router.connect(owner).pause();

      // Admin functions should still work
      await expect(router.connect(owner).setSwapFee(50)).to.not.be.reverted;
      await expect(router.connect(owner).proposeFeeVault(owner.address)).to.not.be.reverted;
    });
  });

  // ===========================================================================
  // 13. isLiquiditySourceRegistered
  // ===========================================================================

  describe("isLiquiditySourceRegistered", function () {
    it("Should return true for a registered source", async function () {
      const { router, sourceId } = await loadFixture(deployRouterFixture);

      expect(await router.isLiquiditySourceRegistered(sourceId)).to.equal(true);
    });

    it("Should return false for an unregistered source", async function () {
      const { router } = await loadFixture(deployRouterFixture);

      const unknownSource = ethers.id("NOT_REGISTERED");
      expect(await router.isLiquiditySourceRegistered(unknownSource)).to.equal(false);
    });

    it("Should return false after a source is removed", async function () {
      const { router, owner, sourceId } = await loadFixture(deployRouterFixture);

      await router.connect(owner).removeLiquiditySource(sourceId);
      expect(await router.isLiquiditySourceRegistered(sourceId)).to.equal(false);
    });
  });

  // ===========================================================================
  // 14. MAX_HOPS constant
  // ===========================================================================

  describe("MAX_HOPS", function () {
    it("Should equal 3", async function () {
      const { router } = await loadFixture(deployRouterFixture);

      expect(await router.MAX_HOPS()).to.equal(3);
    });
  });

  // ===========================================================================
  // 15. BASIS_POINTS_DIVISOR constant
  // ===========================================================================

  describe("BASIS_POINTS_DIVISOR", function () {
    it("Should equal 10000", async function () {
      const { router } = await loadFixture(deployRouterFixture);

      expect(await router.BASIS_POINTS_DIVISOR()).to.equal(10000);
    });
  });

  // ===========================================================================
  // 16. Edge cases & integration
  // ===========================================================================

  describe("Edge cases", function () {
    it("Should handle very small swap amounts correctly", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const tinyAmount = 100n; // 100 wei

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: tinyAmount,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      // Fee: 100 * 30 / 10000 = 0 (rounds down)
      // So full 100 wei goes to swap
      const recipientBal = await tokenB.balanceOf(other.address);
      expect(recipientBal).to.equal(tinyAmount);
    });

    it("Should handle fee rounding down correctly for small amounts", async function () {
      const { router, tokenA, tokenB, sourceId, user, feeVault, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      // 333 wei * 30 / 10000 = 0.999 -> rounds to 0
      const smallAmount = 333n;

      const feeVaultBalBefore = await tokenA.balanceOf(feeVault.address);

      await router.connect(user).swap({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: smallAmount,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceId],
        deadline,
        recipient: other.address,
      });

      const feeVaultBalAfter = await tokenA.balanceOf(feeVault.address);
      // Fee rounds to zero for amounts < 334
      expect(feeVaultBalAfter - feeVaultBalBefore).to.equal(0n);
    });

    it("Should handle swap with adapter returning half the input", async function () {
      const { router, tokenA, tokenB, sourceIdHalf, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const expectedFee = (SWAP_AMOUNT * BigInt(DEFAULT_FEE_BPS)) / BASIS_POINTS_DIVISOR;
      const afterFee = SWAP_AMOUNT - expectedFee;
      const expectedOutput = afterFee / 2n; // 0.5x adapter

      const result = await router.connect(user).swap.staticCall({
        tokenIn: tokenA.target,
        tokenOut: tokenB.target,
        amountIn: SWAP_AMOUNT,
        minAmountOut: 0,
        path: [tokenA.target, tokenB.target],
        sources: [sourceIdHalf],
        deadline,
        recipient: other.address,
      });

      expect(result.amountOut).to.equal(expectedOutput);
    });

    it("Should handle multiple sequential swaps correctly", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      const swapCount = 5;
      const perSwap = ethers.parseEther("100");

      for (let i = 0; i < swapCount; i++) {
        await router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: perSwap,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        });
      }

      const [volume] = await router.getSwapStats();
      expect(volume).to.equal(perSwap * BigInt(swapCount));
    });

    it("Should handle single-element path by reverting with PathMismatch", async function () {
      const { router, tokenA, tokenB, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      // path = [tokenA] with tokenOut = tokenB:
      // path[last] (tokenA) != tokenOut (tokenB), so PathMismatch
      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target],
          sources: [],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "PathMismatch");
    });

    it("Should revert on path with single element and mismatched tokenOut", async function () {
      const { router, tokenA, tokenB, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target],
          sources: [],
          deadline,
          recipient: other.address,
        })
      ).to.be.revertedWithCustomError(router, "PathMismatch");
    });

    it("Should revert when user has insufficient token balance", async function () {
      const { router, tokenA, tokenB, sourceId, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();
      // 'other' has no tokenA balance
      await tokenA.connect(other).approve(router.target, ethers.MaxUint256);

      await expect(
        router.connect(other).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.reverted; // ERC20InsufficientBalance from SafeERC20
    });

    it("Should revert when user has insufficient allowance", async function () {
      const { router, tokenA, tokenB, sourceId, user, other, futureDeadline } =
        await loadFixture(deployRouterFixture);

      const deadline = await futureDeadline();

      // Reset approval to zero
      await tokenA.connect(user).approve(router.target, 0);

      await expect(
        router.connect(user).swap({
          tokenIn: tokenA.target,
          tokenOut: tokenB.target,
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0,
          path: [tokenA.target, tokenB.target],
          sources: [sourceId],
          deadline,
          recipient: other.address,
        })
      ).to.be.reverted; // ERC20InsufficientAllowance from SafeERC20
    });
  });
});
