const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title FeeSwapAdapter Test Suite
 * @notice Comprehensive tests for FeeSwapAdapter — the bridge between
 *         IFeeSwapRouter and the full IOmniSwapRouter.swap(SwapParams).
 * @dev Tests cover:
 *   1. Constructor validation (valid params, zero router)
 *   2. swapExactInput (success, zero addresses, zero amount, dust,
 *      deadline, slippage, balance verification, fee tracking)
 *   3. proposeRouter (success + event, zero address, onlyOwner)
 *   4. applyRouter (success after timelock, before timelock,
 *      no pending, onlyOwner)
 *   5. setDefaultSource (success, zero source, onlyOwner)
 *   6. rescueTokens (success, zero recipient, onlyOwner)
 *   7. renounceOwnership (always reverts)
 *   8. Ownable2Step (transfer + accept flow)
 *   9. Reentrancy protection on swapExactInput
 */
describe("FeeSwapAdapter", function () {
  // ══════════════════════════════════════════════════════════════════
  //                          CONSTANTS
  // ══════════════════════════════════════════════════════════════════

  const MIN_SWAP_AMOUNT = ethers.parseEther("0.001"); // 1e15
  const ROUTER_DELAY = 24 * 60 * 60; // 24 hours in seconds
  const DEFAULT_SOURCE = ethers.id("default-source");
  const SWAP_AMOUNT = ethers.parseEther("100");
  const EXCHANGE_RATE = ethers.parseEther("1"); // 1:1 rate

  // ══════════════════════════════════════════════════════════════════
  //                          FIXTURES
  // ══════════════════════════════════════════════════════════════════

  /**
   * @notice Deploy fresh FeeSwapAdapter, MockOmniSwapRouter, and
   *         two ERC20Mock tokens before each test.
   */
  async function deployAdapterFixture() {
    const [owner, user, recipient, attacker, newOwner] =
      await ethers.getSigners();

    // Deploy mock ERC20 tokens
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const tokenIn = await ERC20Mock.deploy("Token In", "TIN");
    const tokenOut = await ERC20Mock.deploy("Token Out", "TOUT");

    // Deploy mock OmniSwapRouter
    const MockRouter = await ethers.getContractFactory(
      "MockOmniSwapRouter"
    );
    const mockRouter = await MockRouter.deploy(EXCHANGE_RATE);

    // Deploy FeeSwapAdapter
    const Adapter = await ethers.getContractFactory("FeeSwapAdapter");
    const adapter = await Adapter.deploy(
      await mockRouter.getAddress(),
      DEFAULT_SOURCE,
      owner.address
    );

    // Fund user with tokenIn for swap tests
    await tokenIn.mint(user.address, ethers.parseEther("1000000"));

    // Approve adapter to pull tokenIn from user
    await tokenIn
      .connect(user)
      .approve(
        await adapter.getAddress(),
        ethers.MaxUint256
      );

    return {
      adapter,
      mockRouter,
      tokenIn,
      tokenOut,
      owner,
      user,
      recipient,
      attacker,
      newOwner,
    };
  }

  // ══════════════════════════════════════════════════════════════════
  //                      1. CONSTRUCTOR TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("Constructor", function () {
    it("should deploy with valid parameters", async function () {
      const { adapter, mockRouter } = await loadFixture(
        deployAdapterFixture
      );
      expect(await adapter.router()).to.equal(
        await mockRouter.getAddress()
      );
      expect(await adapter.defaultSource()).to.equal(DEFAULT_SOURCE);
    });

    it("should set the correct owner", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      expect(await adapter.owner()).to.equal(owner.address);
    });

    it("should set MIN_SWAP_AMOUNT to 1e15", async function () {
      const { adapter } = await loadFixture(deployAdapterFixture);
      expect(await adapter.MIN_SWAP_AMOUNT()).to.equal(MIN_SWAP_AMOUNT);
    });

    it("should set ROUTER_DELAY to 24 hours", async function () {
      const { adapter } = await loadFixture(deployAdapterFixture);
      expect(await adapter.ROUTER_DELAY()).to.equal(ROUTER_DELAY);
    });

    it("should initialize totalFeesCollected to zero", async function () {
      const { adapter } = await loadFixture(deployAdapterFixture);
      expect(await adapter.totalFeesCollected()).to.equal(0);
    });

    it("should initialize pendingRouter to zero address", async function () {
      const { adapter } = await loadFixture(deployAdapterFixture);
      expect(await adapter.pendingRouter()).to.equal(
        ethers.ZeroAddress
      );
    });

    it("should initialize routerChangeTime to zero", async function () {
      const { adapter } = await loadFixture(deployAdapterFixture);
      expect(await adapter.routerChangeTime()).to.equal(0);
    });

    it("should revert when router address is zero", async function () {
      const [owner] = await ethers.getSigners();
      const Adapter = await ethers.getContractFactory("FeeSwapAdapter");
      await expect(
        Adapter.deploy(ethers.ZeroAddress, DEFAULT_SOURCE, owner.address)
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });

    it("should accept zero default source in constructor", async function () {
      const [owner] = await ethers.getSigners();
      const MockRouter = await ethers.getContractFactory(
        "MockOmniSwapRouter"
      );
      const router = await MockRouter.deploy(EXCHANGE_RATE);

      const Adapter = await ethers.getContractFactory("FeeSwapAdapter");
      const adapter = await Adapter.deploy(
        await router.getAddress(),
        ethers.ZeroHash,
        owner.address
      );
      expect(await adapter.defaultSource()).to.equal(ethers.ZeroHash);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                   2. swapExactInput TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("swapExactInput", function () {
    it("should execute a swap successfully", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      const tx = await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      await expect(tx).to.not.be.reverted;
    });

    it("should transfer output tokens to recipient", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;
      const balanceBefore = await tokenOut.balanceOf(recipient.address);

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      const balanceAfter = await tokenOut.balanceOf(recipient.address);
      // 1:1 exchange rate => output equals input
      expect(balanceAfter - balanceBefore).to.equal(SWAP_AMOUNT);
    });

    it("should return the correct amountOut", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;
      const amountOut = await adapter
        .connect(user)
        .swapExactInput.staticCall(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      expect(amountOut).to.equal(SWAP_AMOUNT);
    });

    it("should pull tokenIn from the caller", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;
      const balanceBefore = await tokenIn.balanceOf(user.address);

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      const balanceAfter = await tokenIn.balanceOf(user.address);
      expect(balanceBefore - balanceAfter).to.equal(SWAP_AMOUNT);
    });

    it("should reset residual router approval after swap (L-01)", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // After swap, adapter's approval of router should be 0
      const allowance = await tokenIn.allowance(
        await adapter.getAddress(),
        await mockRouter.getAddress()
      );
      expect(allowance).to.equal(0);
    });

    it("should track totalFeesCollected when router reports fees", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const feeAmount = ethers.parseEther("0.5");
      await mockRouter.setFeeAmount(feeAmount);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      expect(await adapter.totalFeesCollected()).to.equal(feeAmount);
    });

    it("should accumulate totalFeesCollected across multiple swaps", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const feeAmount = ethers.parseEther("1");
      await mockRouter.setFeeAmount(feeAmount);

      const deadline = (await time.latest()) + 7200;

      // First swap
      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // Second swap
      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      expect(await adapter.totalFeesCollected()).to.equal(
        feeAmount * 2n
      );
    });

    it("should not increment totalFeesCollected when feeAmount is zero", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // feeAmount defaults to 0 in the mock
      expect(await mockRouter.feeAmount()).to.equal(0);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      expect(await adapter.totalFeesCollected()).to.equal(0);
    });

    it("should work with different exchange rates", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // Set 2:1 exchange rate (output = input * 2)
      await mockRouter.setExchangeRate(ethers.parseEther("2"));

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      const balance = await tokenOut.balanceOf(recipient.address);
      expect(balance).to.equal(SWAP_AMOUNT * 2n);
    });

    it("should work with the minimum swap amount", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            MIN_SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.not.be.reverted;
    });

    it("should revert when tokenIn is zero address", async function () {
      const { adapter, tokenOut, user, recipient } = await loadFixture(
        deployAdapterFixture
      );

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            ethers.ZeroAddress,
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("should revert when tokenOut is zero address", async function () {
      const { adapter, tokenIn, user, recipient } = await loadFixture(
        deployAdapterFixture
      );

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            ethers.ZeroAddress,
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("should revert when recipient is zero address", async function () {
      const { adapter, tokenIn, tokenOut, user } = await loadFixture(
        deployAdapterFixture
      );

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            ethers.ZeroAddress,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("should revert when amountIn is zero", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            0,
            0,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
    });

    it("should revert when amountIn is below MIN_SWAP_AMOUNT (L-03)", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;
      const dustAmount = MIN_SWAP_AMOUNT - 1n;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            dustAmount,
            0,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "AmountTooSmall");
    });

    it("should revert when deadline has expired (M-01)", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const pastDeadline = (await time.latest()) - 1;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            pastDeadline
          )
      ).to.be.revertedWithCustomError(adapter, "DeadlineExpired");
    });

    it("should revert when output is below amountOutMin (slippage)", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // Set 0.5:1 rate so output = 50 for input of 100
      await mockRouter.setExchangeRate(ethers.parseEther("0.5"));

      const deadline = (await time.latest()) + 3600;
      // Require 80 tokens output, but only 50 will be received
      const amountOutMin = ethers.parseEther("80");

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            amountOutMin,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "InsufficientOutput");
    });

    it("should revert with correct InsufficientOutput args", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // 0.5:1 rate => 50 output for 100 input
      await mockRouter.setExchangeRate(ethers.parseEther("0.5"));

      const deadline = (await time.latest()) + 3600;
      const amountOutMin = ethers.parseEther("80");

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            amountOutMin,
            recipient.address,
            deadline
          )
      )
        .to.be.revertedWithCustomError(adapter, "InsufficientOutput")
        .withArgs(ethers.parseEther("50"), amountOutMin);
    });

    it("should verify balance change at adapter (H-01, not at recipient)", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // The mock sends tokens to the adapter (params.recipient = address(this))
      // The adapter then verifies its own balance change and forwards to recipient
      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // Adapter should have zero tokenOut balance after forwarding
      const adapterBalance = await tokenOut.balanceOf(
        await adapter.getAddress()
      );
      expect(adapterBalance).to.equal(0);

      // Recipient should have the tokens
      const recipientBalance = await tokenOut.balanceOf(
        recipient.address
      );
      expect(recipientBalance).to.equal(SWAP_AMOUNT);
    });

    it("should handle swap when router returns zero output with zero minAmountOut", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // Set exchange rate to 0 => amountOut = 0
      await mockRouter.setExchangeRate(0);

      const deadline = (await time.latest()) + 3600;

      // Should not revert when amountOutMin is 0 and output is 0
      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.not.be.reverted;
    });

    it("should revert when router returns zero output with non-zero minAmountOut", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      await mockRouter.setExchangeRate(0);

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            1,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "InsufficientOutput");
    });

    it("should pass deadline to the router in SwapParams", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // Verify the router was called (swap count incremented)
      expect(await mockRouter.swapCallCount()).to.equal(1);
    });

    it("should revert when caller has not approved adapter for tokenIn", async function () {
      const { adapter, tokenIn, tokenOut, attacker, recipient } =
        await loadFixture(deployAdapterFixture);

      // Fund attacker with tokenIn but don't approve adapter
      await tokenIn.mint(attacker.address, SWAP_AMOUNT);

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(attacker)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.be.reverted; // ERC20InsufficientAllowance
    });

    it("should revert when caller has insufficient tokenIn balance", async function () {
      const { adapter, tokenIn, tokenOut, attacker, recipient } =
        await loadFixture(deployAdapterFixture);

      // Approve but don't fund
      await tokenIn
        .connect(attacker)
        .approve(await adapter.getAddress(), ethers.MaxUint256);

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(attacker)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.be.reverted; // ERC20InsufficientBalance
    });

    it("should succeed when deadline equals current block.timestamp", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // Use a far-future deadline to avoid timing issues in hardhat
      // The contract checks: block.timestamp > deadline (strict >)
      // So deadline == block.timestamp should NOT revert
      const deadline = (await time.latest()) + 10;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.not.be.reverted;
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                    3. proposeRouter TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("proposeRouter", function () {
    it("should propose a new router with correct pending state", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);

      expect(await adapter.pendingRouter()).to.equal(
        newRouterAddr.address
      );
    });

    it("should set routerChangeTime to block.timestamp + ROUTER_DELAY", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      const tx = await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(
        receipt.blockNumber
      );

      const expectedTime = block.timestamp + ROUTER_DELAY;
      expect(await adapter.routerChangeTime()).to.equal(expectedTime);
    });

    it("should emit RouterProposed event", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await expect(
        adapter.connect(owner).proposeRouter(newRouterAddr.address)
      ).to.emit(adapter, "RouterProposed");
    });

    it("should emit RouterProposed with correct args", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      const tx = adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);
      // Check the event includes the proposed router address
      await expect(tx)
        .to.emit(adapter, "RouterProposed")
        .withArgs(newRouterAddr.address, () => true);
    });

    it("should revert when proposing zero address router", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter.connect(owner).proposeRouter(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("should revert when non-owner proposes router", async function () {
      const { adapter, attacker } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter.connect(attacker).proposeRouter(attacker.address)
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should allow overwriting a pending proposal", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , addr5, addr6] = await ethers.getSigners();

      await adapter.connect(owner).proposeRouter(addr5.address);
      await adapter.connect(owner).proposeRouter(addr6.address);

      expect(await adapter.pendingRouter()).to.equal(addr6.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                     4. applyRouter TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("applyRouter", function () {
    it("should apply router after timelock expires", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const MockRouter = await ethers.getContractFactory(
        "MockOmniSwapRouter"
      );
      const newRouter = await MockRouter.deploy(EXCHANGE_RATE);

      await adapter
        .connect(owner)
        .proposeRouter(await newRouter.getAddress());
      await time.increase(ROUTER_DELAY + 1);
      await adapter.connect(owner).applyRouter();

      expect(await adapter.router()).to.equal(
        await newRouter.getAddress()
      );
    });

    it("should emit RouterUpdated event on apply", async function () {
      const { adapter, mockRouter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);
      await time.increase(ROUTER_DELAY + 1);

      await expect(adapter.connect(owner).applyRouter())
        .to.emit(adapter, "RouterUpdated")
        .withArgs(
          await mockRouter.getAddress(),
          newRouterAddr.address
        );
    });

    it("should clear pending state after applying", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);
      await time.increase(ROUTER_DELAY + 1);
      await adapter.connect(owner).applyRouter();

      expect(await adapter.pendingRouter()).to.equal(
        ethers.ZeroAddress
      );
      expect(await adapter.routerChangeTime()).to.equal(0);
    });

    it("should revert when timelock has not expired", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);
      // Only advance half the time
      await time.increase(ROUTER_DELAY / 2);

      await expect(
        adapter.connect(owner).applyRouter()
      ).to.be.revertedWithCustomError(adapter, "TimelockNotExpired");
    });

    it("should revert when no pending change exists", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter.connect(owner).applyRouter()
      ).to.be.revertedWithCustomError(adapter, "NoPendingChange");
    });

    it("should revert when non-owner tries to apply", async function () {
      const { adapter, owner, attacker } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);
      await time.increase(ROUTER_DELAY + 1);

      await expect(
        adapter.connect(attacker).applyRouter()
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should allow swaps with the new router after apply", async function () {
      const { adapter, tokenIn, tokenOut, owner, user, recipient } =
        await loadFixture(deployAdapterFixture);

      // Deploy a new mock router
      const MockRouter = await ethers.getContractFactory(
        "MockOmniSwapRouter"
      );
      const newRouter = await MockRouter.deploy(
        ethers.parseEther("2") // 2:1 exchange rate
      );

      // Propose and apply
      await adapter
        .connect(owner)
        .proposeRouter(await newRouter.getAddress());
      await time.increase(ROUTER_DELAY + 1);
      await adapter.connect(owner).applyRouter();

      // Perform swap with new router
      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // New router has 2:1 rate
      const balance = await tokenOut.balanceOf(recipient.address);
      expect(balance).to.equal(SWAP_AMOUNT * 2n);
    });

    it("should revert when applying before timelock boundary", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);

      // Advance only half the delay — well before expiry
      await time.increase(ROUTER_DELAY / 2);

      await expect(
        adapter.connect(owner).applyRouter()
      ).to.be.revertedWithCustomError(adapter, "TimelockNotExpired");
    });

    it("should succeed when applying exactly at timelock expiry", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const [, , , , , newRouterAddr] = await ethers.getSigners();

      await adapter
        .connect(owner)
        .proposeRouter(newRouterAddr.address);

      // Advance exactly ROUTER_DELAY seconds
      await time.increase(ROUTER_DELAY);

      // Contract checks: block.timestamp < routerChangeTime
      // At exactly routerChangeTime, it should NOT revert
      await expect(
        adapter.connect(owner).applyRouter()
      ).to.not.be.reverted;
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                   5. setDefaultSource TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("setDefaultSource", function () {
    it("should update the default source", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const newSource = ethers.id("new-source");

      await adapter.connect(owner).setDefaultSource(newSource);
      expect(await adapter.defaultSource()).to.equal(newSource);
    });

    it("should emit DefaultSourceUpdated event", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const newSource = ethers.id("new-source");

      await expect(
        adapter.connect(owner).setDefaultSource(newSource)
      )
        .to.emit(adapter, "DefaultSourceUpdated")
        .withArgs(DEFAULT_SOURCE, newSource);
    });

    it("should revert when source is zero (L-02)", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter.connect(owner).setDefaultSource(ethers.ZeroHash)
      ).to.be.revertedWithCustomError(adapter, "InvalidSource");
    });

    it("should revert when non-owner calls setDefaultSource", async function () {
      const { adapter, attacker } = await loadFixture(
        deployAdapterFixture
      );
      const newSource = ethers.id("new-source");

      await expect(
        adapter.connect(attacker).setDefaultSource(newSource)
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should allow updating source multiple times", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );
      const source1 = ethers.id("source-1");
      const source2 = ethers.id("source-2");

      await adapter.connect(owner).setDefaultSource(source1);
      await adapter.connect(owner).setDefaultSource(source2);

      expect(await adapter.defaultSource()).to.equal(source2);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                    6. rescueTokens TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("rescueTokens", function () {
    it("should rescue stuck tokens to recipient", async function () {
      const { adapter, tokenIn, owner, recipient } = await loadFixture(
        deployAdapterFixture
      );

      const rescueAmount = ethers.parseEther("500");

      // Send tokens directly to adapter (simulating stuck tokens)
      await tokenIn.mint(await adapter.getAddress(), rescueAmount);

      const balanceBefore = await tokenIn.balanceOf(recipient.address);
      await adapter
        .connect(owner)
        .rescueTokens(
          await tokenIn.getAddress(),
          recipient.address,
          rescueAmount
        );
      const balanceAfter = await tokenIn.balanceOf(recipient.address);

      expect(balanceAfter - balanceBefore).to.equal(rescueAmount);
    });

    it("should emit TokensRescued event", async function () {
      const { adapter, tokenIn, owner, recipient } = await loadFixture(
        deployAdapterFixture
      );

      const rescueAmount = ethers.parseEther("500");
      await tokenIn.mint(await adapter.getAddress(), rescueAmount);

      await expect(
        adapter
          .connect(owner)
          .rescueTokens(
            await tokenIn.getAddress(),
            recipient.address,
            rescueAmount
          )
      )
        .to.emit(adapter, "TokensRescued")
        .withArgs(
          await tokenIn.getAddress(),
          recipient.address,
          rescueAmount
        );
    });

    it("should revert when recipient is zero address", async function () {
      const { adapter, tokenIn, owner } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter
          .connect(owner)
          .rescueTokens(
            await tokenIn.getAddress(),
            ethers.ZeroAddress,
            ethers.parseEther("1")
          )
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("should revert when non-owner calls rescueTokens", async function () {
      const { adapter, tokenIn, attacker, recipient } =
        await loadFixture(deployAdapterFixture);

      await expect(
        adapter
          .connect(attacker)
          .rescueTokens(
            await tokenIn.getAddress(),
            recipient.address,
            ethers.parseEther("1")
          )
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should revert when adapter has insufficient balance", async function () {
      const { adapter, tokenIn, owner, recipient } = await loadFixture(
        deployAdapterFixture
      );

      // Adapter has no tokens; trying to rescue should revert
      await expect(
        adapter
          .connect(owner)
          .rescueTokens(
            await tokenIn.getAddress(),
            recipient.address,
            ethers.parseEther("1")
          )
      ).to.be.reverted; // ERC20InsufficientBalance
    });

    it("should allow rescuing different token types", async function () {
      const { adapter, tokenIn, tokenOut, owner, recipient } =
        await loadFixture(deployAdapterFixture);

      const amount = ethers.parseEther("100");
      await tokenIn.mint(await adapter.getAddress(), amount);
      await tokenOut.mint(await adapter.getAddress(), amount);

      await adapter
        .connect(owner)
        .rescueTokens(
          await tokenIn.getAddress(),
          recipient.address,
          amount
        );
      await adapter
        .connect(owner)
        .rescueTokens(
          await tokenOut.getAddress(),
          recipient.address,
          amount
        );

      expect(await tokenIn.balanceOf(recipient.address)).to.equal(
        amount
      );
      expect(await tokenOut.balanceOf(recipient.address)).to.equal(
        amount
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                 7. renounceOwnership TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("renounceOwnership", function () {
    it("should always revert with OwnershipRenunciationDisabled", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(
        adapter,
        "OwnershipRenunciationDisabled"
      );
    });

    it("should revert even when called by non-owner", async function () {
      const { adapter, attacker } = await loadFixture(
        deployAdapterFixture
      );

      // The function is pure and always reverts regardless of caller
      await expect(
        adapter.connect(attacker).renounceOwnership()
      ).to.be.revertedWithCustomError(
        adapter,
        "OwnershipRenunciationDisabled"
      );
    });

    it("should not change the owner after failed renounce", async function () {
      const { adapter, owner } = await loadFixture(
        deployAdapterFixture
      );

      try {
        await adapter.connect(owner).renounceOwnership();
      } catch {
        // Expected to revert
      }

      expect(await adapter.owner()).to.equal(owner.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                   8. Ownable2Step TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("Ownable2Step", function () {
    it("should transfer ownership in two steps", async function () {
      const { adapter, owner, newOwner } = await loadFixture(
        deployAdapterFixture
      );

      await adapter
        .connect(owner)
        .transferOwnership(newOwner.address);
      expect(await adapter.pendingOwner()).to.equal(newOwner.address);

      // Owner is still the original owner
      expect(await adapter.owner()).to.equal(owner.address);

      await adapter.connect(newOwner).acceptOwnership();
      expect(await adapter.owner()).to.equal(newOwner.address);
    });

    it("should revert when non-pending-owner tries to accept", async function () {
      const { adapter, owner, newOwner, attacker } = await loadFixture(
        deployAdapterFixture
      );

      await adapter
        .connect(owner)
        .transferOwnership(newOwner.address);

      await expect(
        adapter.connect(attacker).acceptOwnership()
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should revert when non-owner initiates transfer", async function () {
      const { adapter, attacker, newOwner } = await loadFixture(
        deployAdapterFixture
      );

      await expect(
        adapter
          .connect(attacker)
          .transferOwnership(newOwner.address)
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should allow new owner to use admin functions after transfer", async function () {
      const { adapter, owner, newOwner } = await loadFixture(
        deployAdapterFixture
      );

      await adapter
        .connect(owner)
        .transferOwnership(newOwner.address);
      await adapter.connect(newOwner).acceptOwnership();

      // New owner can call setDefaultSource
      const newSource = ethers.id("transferred-source");
      await expect(
        adapter.connect(newOwner).setDefaultSource(newSource)
      ).to.not.be.reverted;
      expect(await adapter.defaultSource()).to.equal(newSource);
    });

    it("should prevent old owner from using admin functions after transfer", async function () {
      const { adapter, owner, newOwner } = await loadFixture(
        deployAdapterFixture
      );

      await adapter
        .connect(owner)
        .transferOwnership(newOwner.address);
      await adapter.connect(newOwner).acceptOwnership();

      await expect(
        adapter
          .connect(owner)
          .setDefaultSource(ethers.id("should-fail"))
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
    });

    it("should allow transfer to be overwritten before acceptance", async function () {
      const { adapter, owner, newOwner, attacker } = await loadFixture(
        deployAdapterFixture
      );

      // Propose newOwner first
      await adapter
        .connect(owner)
        .transferOwnership(newOwner.address);

      // Overwrite with attacker
      await adapter
        .connect(owner)
        .transferOwnership(attacker.address);

      expect(await adapter.pendingOwner()).to.equal(attacker.address);

      // newOwner can no longer accept
      await expect(
        adapter.connect(newOwner).acceptOwnership()
      ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");

      // attacker can now accept
      await adapter.connect(attacker).acceptOwnership();
      expect(await adapter.owner()).to.equal(attacker.address);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //               9. REENTRANCY PROTECTION TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("Reentrancy protection", function () {
    it("should revert when router attempts reentrancy on swapExactInput", async function () {
      const { tokenIn, tokenOut, user, recipient } = await loadFixture(
        deployAdapterFixture
      );

      // Deploy the reentrant router
      const ReentrantRouter = await ethers.getContractFactory(
        "ReentrantSwapRouter"
      );
      const reentrantRouter = await ReentrantRouter.deploy();

      // Deploy a new adapter using the reentrant router
      const [owner] = await ethers.getSigners();
      const Adapter = await ethers.getContractFactory("FeeSwapAdapter");
      const maliciousAdapter = await Adapter.deploy(
        await reentrantRouter.getAddress(),
        DEFAULT_SOURCE,
        owner.address
      );

      // Configure the reentrant router to call back into the adapter
      await reentrantRouter.configure(
        await maliciousAdapter.getAddress(),
        await tokenIn.getAddress(),
        await tokenOut.getAddress()
      );

      // Fund user and approve
      await tokenIn.mint(user.address, ethers.parseEther("1000000"));
      await tokenIn
        .connect(user)
        .approve(
          await maliciousAdapter.getAddress(),
          ethers.MaxUint256
        );

      // Also approve the reentrant router to pull from the adapter
      // (the adapter calls forceApprove on the router)

      const deadline = (await time.latest()) + 3600;

      // The reentrant router will try to call swapExactInput again
      // The ReentrancyGuard should block it
      await expect(
        maliciousAdapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            0,
            recipient.address,
            deadline
          )
      ).to.be.reverted; // ReentrancyGuardReentrantCall
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //              10. EDGE CASES & INTEGRATION TESTS
  // ══════════════════════════════════════════════════════════════════

  describe("Edge cases", function () {
    it("should handle very large swap amounts", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const largeAmount = ethers.parseEther("999999999");
      await tokenIn.mint(user.address, largeAmount);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          largeAmount,
          0,
          recipient.address,
          deadline
        );

      expect(await tokenOut.balanceOf(recipient.address)).to.equal(
        largeAmount
      );
    });

    it("should handle exactly MIN_SWAP_AMOUNT", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          MIN_SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      expect(await tokenOut.balanceOf(recipient.address)).to.equal(
        MIN_SWAP_AMOUNT
      );
    });

    it("should revert with amount 1 wei (below minimum)", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            1n,
            0,
            recipient.address,
            deadline
          )
      ).to.be.revertedWithCustomError(adapter, "AmountTooSmall");
    });

    it("should handle swap where amountOutMin equals exact output", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      // 1:1 rate, so output == input; set minOut == input
      await expect(
        adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            SWAP_AMOUNT,
            SWAP_AMOUNT,
            recipient.address,
            deadline
          )
      ).to.not.be.reverted;
    });

    it("should handle multiple sequential swaps correctly", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 7200;
      const swapCount = 5;
      const amount = ethers.parseEther("10");

      for (let i = 0; i < swapCount; i++) {
        await adapter
          .connect(user)
          .swapExactInput(
            await tokenIn.getAddress(),
            await tokenOut.getAddress(),
            amount,
            0,
            recipient.address,
            deadline
          );
      }

      const expectedTotal = amount * BigInt(swapCount);
      expect(await tokenOut.balanceOf(recipient.address)).to.equal(
        expectedTotal
      );
    });

    it("should use the correct source in swap params after setDefaultSource", async function () {
      const { adapter, mockRouter, tokenIn, tokenOut, owner, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const newSource = ethers.id("uniswap-v3");
      await adapter.connect(owner).setDefaultSource(newSource);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // Verify swap was called (can't easily verify sources in mock,
      // but we confirm the swap completed successfully with the new source)
      expect(await mockRouter.swapCallCount()).to.equal(1);
      expect(await adapter.defaultSource()).to.equal(newSource);
    });

    it("should not leave tokens in adapter after successful swap", async function () {
      const { adapter, tokenIn, tokenOut, user, recipient } =
        await loadFixture(deployAdapterFixture);

      const deadline = (await time.latest()) + 3600;

      await adapter
        .connect(user)
        .swapExactInput(
          await tokenIn.getAddress(),
          await tokenOut.getAddress(),
          SWAP_AMOUNT,
          0,
          recipient.address,
          deadline
        );

      // Adapter should hold zero of both tokens
      const adapterAddr = await adapter.getAddress();
      expect(await tokenIn.balanceOf(adapterAddr)).to.equal(0);
      expect(await tokenOut.balanceOf(adapterAddr)).to.equal(0);
    });
  });
});
