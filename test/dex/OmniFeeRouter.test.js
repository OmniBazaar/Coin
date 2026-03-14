const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title OmniFeeRouter Test Suite
 * @notice Tests for the trustless fee-collecting DEX swap router.
 * @dev Validates constructor guards, immutable getters, swapWithFee input
 *      validation, rescueTokens access control, and edge cases.
 *
 *      Uses contracts/test/MockERC20.sol (2-arg constructor: name, symbol)
 *      with separate mint() calls for token distribution.
 */
describe("OmniFeeRouter", function () {
  let feeRouter;
  let inputToken;
  let outputToken;
  let dummyRouter; // A deployed contract used as a valid router address (has code)
  let owner, feeCollector, user, other;

  /** Default maxFeeBps: 100 = 1.00% */
  const MAX_FEE_BPS = 100;
  const BPS_DENOMINATOR = 10_000;
  const TOTAL_AMOUNT = ethers.parseEther("1000");
  const ROUTER_ALLOWLIST_DELAY = 12 * 3600; // 12 hours in seconds

  /**
   * Helper: perform the full propose-wait-apply router allowlist change.
   * 1. Call proposeRouterChange(router, allowed)
   * 2. Advance time by ROUTER_ALLOWLIST_DELAY
   * 3. Call applyRouterChange()
   *
   * @param {object} routerContract - The OmniFeeRouter contract instance
   * @param {object} signer - The owner signer
   * @param {string} routerAddr - The router address to allow/disallow
   * @param {boolean} allowed - Whether to allow or disallow
   */
  async function allowRouterViaTimelock(routerContract, signer, routerAddr, allowed) {
    await routerContract.connect(signer).proposeRouterChange(routerAddr, allowed);
    await ethers.provider.send("evm_increaseTime", [ROUTER_ALLOWLIST_DELAY]);
    await ethers.provider.send("evm_mine", []);
    await routerContract.connect(signer).applyRouterChange();
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeCollector = signers[1];
    user = signers[2];
    other = signers[3];

    // Deploy two MockERC20 tokens (2-arg constructor from contracts/test/MockERC20.sol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    inputToken = await MockERC20.deploy("Input Token", "IN");
    outputToken = await MockERC20.deploy("Output Token", "OUT");

    // Deploy a dummy contract to use as a valid router address (has code, not token or feeRouter)
    dummyRouter = await MockERC20.deploy("Dummy Router", "DUMMY");

    // Deploy OmniFeeRouter with valid parameters (3-arg constructor: feeCollector, maxFeeBps, trustedForwarder)
    const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
    feeRouter = await OmniFeeRouter.deploy(feeCollector.address, MAX_FEE_BPS, ethers.ZeroAddress);

    // R6 M-01: Allowlist the dummy router for swap tests (timelocked)
    await allowRouterViaTimelock(feeRouter, owner, dummyRouter.target, true);

    // Give user some input tokens and approve the fee router
    await inputToken.mint(user.address, TOTAL_AMOUNT);
    await inputToken.connect(user).approve(feeRouter.target, TOTAL_AMOUNT);
  });

  // ---------------------------------------------------------------------------
  // Deployment Tests
  // ---------------------------------------------------------------------------

  describe("Deployment", function () {
    it("Should deploy with valid feeCollector and maxFeeBps", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      const router = await OmniFeeRouter.deploy(feeCollector.address, 200, ethers.ZeroAddress);
      expect(router.target).to.be.properAddress;
    });

    it("Should revert with InvalidFeeCollector when feeCollector is zero address", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      await expect(
        OmniFeeRouter.deploy(ethers.ZeroAddress, MAX_FEE_BPS, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        { interface: OmniFeeRouter.interface },
        "InvalidFeeCollector"
      );
    });

    it("Should revert with FeeExceedsCap when maxFeeBps is 0", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      await expect(
        OmniFeeRouter.deploy(feeCollector.address, 0, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        { interface: OmniFeeRouter.interface },
        "FeeExceedsCap"
      );
    });

    it("Should revert with FeeExceedsCap when maxFeeBps exceeds 500", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      await expect(
        OmniFeeRouter.deploy(feeCollector.address, 501, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(
        { interface: OmniFeeRouter.interface },
        "FeeExceedsCap"
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable State Getters
  // ---------------------------------------------------------------------------

  describe("Immutable State", function () {
    it("Should return the correct feeCollector address", async function () {
      expect(await feeRouter.feeCollector()).to.equal(feeCollector.address);
    });

    it("Should return the correct maxFeeBps value", async function () {
      expect(await feeRouter.maxFeeBps()).to.equal(MAX_FEE_BPS);
    });
  });

  // ---------------------------------------------------------------------------
  // swapWithFee Revert Conditions
  // ---------------------------------------------------------------------------

  describe("swapWithFee — revert conditions", function () {
    /**
     * Computes a far-future deadline from the current Hardhat block timestamp.
     * Using Date.now() is unreliable because the Hardhat node's timestamp drifts
     * after hundreds of preceding tests advance block time.
     */
    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    it("Should revert with DeadlineExpired when deadline is in the past", async function () {
      // Use a deadline of 1 (already expired)
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          other.address,
          "0x",
          0,
          1                         // expired deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "DeadlineExpired");
    });

    it("Should revert with ZeroAmount when totalAmount is 0", async function () {
      const deadline = await farFutureDeadline();
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          0,                        // totalAmount = 0
          0,                        // feeAmount
          dummyRouter.target,       // routerAddress (contract with code)
          "0x",                     // routerCalldata
          0,                        // minOutput
          deadline                  // deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "ZeroAmount");
    });

    it("Should revert with InvalidTokenAddress when inputToken is zero address", async function () {
      const deadline = await farFutureDeadline();
      await expect(
        feeRouter.connect(user).swapWithFee(
          ethers.ZeroAddress,       // inputToken = zero
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          other.address,
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidTokenAddress");
    });

    it("Should revert with InvalidTokenAddress when outputToken is zero address", async function () {
      const deadline = await farFutureDeadline();
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          ethers.ZeroAddress,       // outputToken = zero
          TOTAL_AMOUNT,
          0,
          other.address,
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidTokenAddress");
    });

    it("Should revert with InvalidRouterAddress when routerAddress is zero address", async function () {
      const deadline = await farFutureDeadline();
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          ethers.ZeroAddress,       // routerAddress = zero
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });

    it("Should revert with FeeExceedsTotal when feeAmount > totalAmount", async function () {
      const deadline = await farFutureDeadline();
      const feeAmount = TOTAL_AMOUNT + 1n; // fee larger than total
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          feeAmount,
          dummyRouter.target,       // contract with code
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "FeeExceedsTotal");
    });

    it("Should revert with FeeExceedsCap when fee exceeds maxFeeBps cap", async function () {
      const deadline = await farFutureDeadline();
      // maxFeeBps = 100 = 1%, so max allowed fee on 1000 tokens = 10 tokens
      // Requesting anything above 10 tokens should exceed the cap
      const maxAllowed = (TOTAL_AMOUNT * BigInt(MAX_FEE_BPS)) / BigInt(BPS_DENOMINATOR);
      const feeAmount = maxAllowed + 1n;

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          feeAmount,
          dummyRouter.target,       // contract with code
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens
  // ---------------------------------------------------------------------------

  describe("rescueTokens", function () {
    it("Should allow owner to rescue tokens stuck in the contract", async function () {
      // Send some tokens directly to the feeRouter contract (simulating stuck tokens)
      const rescueAmount = ethers.parseEther("50");
      await inputToken.mint(feeRouter.target, rescueAmount);

      const collectorBalanceBefore = await inputToken.balanceOf(feeCollector.address);

      // R6: rescueTokens is now onlyOwner (Ownable2Step), not feeCollector-gated
      await feeRouter.connect(owner).rescueTokens(inputToken.target);

      const collectorBalanceAfter = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalanceAfter - collectorBalanceBefore).to.equal(rescueAmount);

      // Contract balance should be zero after rescue
      expect(await inputToken.balanceOf(feeRouter.target)).to.equal(0);
    });

    it("Should revert with OwnableUnauthorizedAccount when called by non-owner", async function () {
      // Send some tokens to the contract so there is something to rescue
      await inputToken.mint(feeRouter.target, ethers.parseEther("50"));

      // R6: rescueTokens is now onlyOwner, so non-owner gets OwnableUnauthorizedAccount
      await expect(
        feeRouter.connect(user).rescueTokens(inputToken.target)
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should succeed silently when no tokens are stuck", async function () {
      // Contract has zero balance — rescue should not revert
      const collectorBalanceBefore = await inputToken.balanceOf(feeCollector.address);
      // R6: rescueTokens is now onlyOwner
      await feeRouter.connect(owner).rescueTokens(inputToken.target);
      const collectorBalanceAfter = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalanceAfter).to.equal(collectorBalanceBefore);
    });
  });

  // ---------------------------------------------------------------------------
  // Fee Routing — Successful Swaps
  // ---------------------------------------------------------------------------

  describe("swapWithFee — successful swap flow", function () {
    let mockRouter;
    const SWAP_AMOUNT = ethers.parseEther("100");

    /**
     * Computes a far-future deadline from the current Hardhat block timestamp.
     */
    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    beforeEach(async function () {
      // Deploy the mock DEX router (1:1 exchange rate = 1e18)
      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      mockRouter = await MockDEXRouter.deploy(ethers.parseEther("1")); // 1:1 rate

      // Allowlist the mock router (timelocked)
      await allowRouterViaTimelock(feeRouter, owner, mockRouter.target, true);

      // Give user tokens and approve fee router
      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);
    });

    it("Should execute a swap with zero fee", async function () {
      const deadline = await farFutureDeadline();
      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        0,                        // zero fee
        mockRouter.target,
        calldata,
        0,                        // minOutput
        deadline
      );

      // User should receive output tokens (1:1 rate)
      const userOutputBalance = await outputToken.balanceOf(user.address);
      expect(userOutputBalance).to.equal(SWAP_AMOUNT);

      // Fee collector should receive nothing
      const collectorBalance = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalance).to.equal(0);
    });

    it("Should execute a swap with fee and split correctly", async function () {
      const deadline = await farFutureDeadline();
      // maxFeeBps = 100 = 1%, so max fee on 100 tokens = 1 token
      const feeAmount = ethers.parseEther("1"); // 1% of 100
      const netAmount = SWAP_AMOUNT - feeAmount;

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        netAmount
      ]);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      // Fee collector gets feeAmount
      const collectorBalance = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalance).to.equal(feeAmount);

      // User gets output tokens for the net amount (1:1 rate)
      const userOutputBalance = await outputToken.balanceOf(user.address);
      expect(userOutputBalance).to.equal(netAmount);

      // Fee router contract should hold nothing
      const routerInputBalance = await inputToken.balanceOf(feeRouter.target);
      expect(routerInputBalance).to.equal(0);
    });

    it("Should update totalFeesCollected after swap with fee", async function () {
      const deadline = await farFutureDeadline();
      const feeAmount = ethers.parseEther("0.5");
      const netAmount = SWAP_AMOUNT - feeAmount;

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        netAmount
      ]);

      const feesBefore = await feeRouter.totalFeesCollected();

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      const feesAfter = await feeRouter.totalFeesCollected();
      expect(feesAfter - feesBefore).to.equal(feeAmount);
    });

    it("Should sweep residual input tokens back to user", async function () {
      const deadline = await farFutureDeadline();
      const feeAmount = 0n;
      const residualAmount = ethers.parseEther("10");

      // Configure mock router to leave some tokens unconsumed
      await mockRouter.setLeaveUnconsumed(residualAmount);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      const userInputBefore = await inputToken.balanceOf(user.address);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      // User should get residual input tokens back (spent SWAP_AMOUNT, got residualAmount back)
      const userInputAfter = await inputToken.balanceOf(user.address);
      expect(userInputBefore - userInputAfter).to.equal(SWAP_AMOUNT - residualAmount);

      // Fee router should hold nothing
      const routerBalance = await inputToken.balanceOf(feeRouter.target);
      expect(routerBalance).to.equal(0);
    });

    it("Should revert with InsufficientOutputTokens when output below minOutput", async function () {
      const deadline = await farFutureDeadline();

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      // Request minimum output larger than what the swap produces (1:1 rate)
      const minOutput = SWAP_AMOUNT + 1n;

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,
          0,
          mockRouter.target,
          calldata,
          minOutput,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InsufficientOutputTokens");
    });

    it("Should revert with RouterCallFailed when the router reverts", async function () {
      const deadline = await farFutureDeadline();

      // Tell mock router to revert
      await mockRouter.setShouldRevert(true);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,
          0,
          mockRouter.target,
          calldata,
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "RouterCallFailed");
    });
  });

  // ---------------------------------------------------------------------------
  // Fee Amount Bounds
  // ---------------------------------------------------------------------------

  describe("swapWithFee — fee amount bounds", function () {
    let mockRouter;
    const SWAP_AMOUNT = ethers.parseEther("100");

    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    beforeEach(async function () {
      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      mockRouter = await MockDEXRouter.deploy(ethers.parseEther("1"));
      await allowRouterViaTimelock(feeRouter, owner, mockRouter.target, true);
      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);
    });

    it("Should accept fee exactly at maxFeeBps cap", async function () {
      const deadline = await farFutureDeadline();
      // maxFeeBps = 100 = 1%, so exactly 1 token on 100 tokens
      const feeAmount = (SWAP_AMOUNT * BigInt(MAX_FEE_BPS)) / BigInt(BPS_DENOMINATOR);
      const netAmount = SWAP_AMOUNT - feeAmount;

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        netAmount
      ]);

      // Should not revert — fee is exactly at cap
      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      const collectorBalance = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalance).to.equal(feeAmount);
    });

    it("Should accept fee equal to totalAmount when within maxFeeBps", async function () {
      // Deploy a new router with 100% fee cap (maxFeeBps = 500 = 5% — max allowed)
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      const highFeeRouter = await OmniFeeRouter.deploy(feeCollector.address, 500, ethers.ZeroAddress);

      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      const router2 = await MockDEXRouter.deploy(ethers.parseEther("1"));
      await allowRouterViaTimelock(highFeeRouter, owner, router2.target, true);

      // Fee = 5% of 100 = 5 tokens
      const feeAmount = (SWAP_AMOUNT * 500n) / 10000n;
      const netAmount = SWAP_AMOUNT - feeAmount;
      const deadline = await farFutureDeadline();

      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(highFeeRouter.target, SWAP_AMOUNT);

      const calldata = router2.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        netAmount
      ]);

      await highFeeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        router2.target,
        calldata,
        0,
        deadline
      );

      const collectorBalance = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalance).to.equal(feeAmount);
    });

    it("Should revert with AmountTooSmall when totalAmount below MIN_SWAP_AMOUNT", async function () {
      const deadline = await farFutureDeadline();
      const dustAmount = ethers.parseUnits("1", 14); // 1e14, below MIN_SWAP_AMOUNT (1e15)

      await inputToken.mint(user.address, dustAmount);
      await inputToken.connect(user).approve(feeRouter.target, dustAmount);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        dustAmount
      ]);

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          dustAmount,
          0,
          mockRouter.target,
          calldata,
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "AmountTooSmall");
    });

    it("Should accept totalAmount exactly at MIN_SWAP_AMOUNT", async function () {
      const deadline = await farFutureDeadline();
      const minAmount = ethers.parseUnits("1", 15); // exactly MIN_SWAP_AMOUNT

      await inputToken.mint(user.address, minAmount);
      await inputToken.connect(user).approve(feeRouter.target, minAmount);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        minAmount
      ]);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        minAmount,
        0,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      const userOutput = await outputToken.balanceOf(user.address);
      expect(userOutput).to.equal(minAmount);
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-Token Support
  // ---------------------------------------------------------------------------

  describe("swapWithFee — multi-token support", function () {
    let mockRouter;
    let tokenA, tokenB, tokenC;
    const SWAP_AMOUNT = ethers.parseEther("200");

    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    beforeEach(async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      tokenA = await MockERC20.deploy("Token A", "TKA");
      tokenB = await MockERC20.deploy("Token B", "TKB");
      tokenC = await MockERC20.deploy("Token C", "TKC");

      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      mockRouter = await MockDEXRouter.deploy(ethers.parseEther("2")); // 2:1 rate

      await allowRouterViaTimelock(feeRouter, owner, mockRouter.target, true);
    });

    it("Should swap tokenA for tokenB with 2:1 exchange rate", async function () {
      const deadline = await farFutureDeadline();

      await tokenA.mint(user.address, SWAP_AMOUNT);
      await tokenA.connect(user).approve(feeRouter.target, SWAP_AMOUNT);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        tokenA.target,
        tokenB.target,
        SWAP_AMOUNT
      ]);

      await feeRouter.connect(user).swapWithFee(
        tokenA.target,
        tokenB.target,
        SWAP_AMOUNT,
        0,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      const userTokenBBalance = await tokenB.balanceOf(user.address);
      // 200 * 2 = 400 output tokens at 2:1 rate
      expect(userTokenBBalance).to.equal(SWAP_AMOUNT * 2n);
    });

    it("Should swap tokenB for tokenC with fee deducted from tokenB input", async function () {
      const deadline = await farFutureDeadline();
      const feeAmount = (SWAP_AMOUNT * BigInt(MAX_FEE_BPS)) / BigInt(BPS_DENOMINATOR);
      const netAmount = SWAP_AMOUNT - feeAmount;

      await tokenB.mint(user.address, SWAP_AMOUNT);
      await tokenB.connect(user).approve(feeRouter.target, SWAP_AMOUNT);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        tokenB.target,
        tokenC.target,
        netAmount
      ]);

      await feeRouter.connect(user).swapWithFee(
        tokenB.target,
        tokenC.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      // Fee collector gets tokenB
      const collectorTokenB = await tokenB.balanceOf(feeCollector.address);
      expect(collectorTokenB).to.equal(feeAmount);

      // User gets tokenC (netAmount * 2 at 2:1 rate)
      const userTokenC = await tokenC.balanceOf(user.address);
      expect(userTokenC).to.equal(netAmount * 2n);
    });

    it("Should revert with InvalidTokenAddress when inputToken equals outputToken", async function () {
      const deadline = await farFutureDeadline();

      await tokenA.mint(user.address, SWAP_AMOUNT);
      await tokenA.connect(user).approve(feeRouter.target, SWAP_AMOUNT);

      await expect(
        feeRouter.connect(user).swapWithFee(
          tokenA.target,
          tokenA.target,      // same as input
          SWAP_AMOUNT,
          0,
          mockRouter.target,
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidTokenAddress");
    });
  });

  // ---------------------------------------------------------------------------
  // Router Allowlist
  // ---------------------------------------------------------------------------

  describe("proposeRouterChange / applyRouterChange / cancelRouterChange", function () {
    it("Should allow owner to propose and apply adding a router to the allowlist", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await allowRouterViaTimelock(feeRouter, owner, contractRouter.target, true);
      expect(await feeRouter.allowedRouters(contractRouter.target)).to.equal(true);
    });

    it("Should allow owner to propose and apply removing a router from the allowlist", async function () {
      // dummyRouter was added in beforeEach
      expect(await feeRouter.allowedRouters(dummyRouter.target)).to.equal(true);

      await allowRouterViaTimelock(feeRouter, owner, dummyRouter.target, false);
      expect(await feeRouter.allowedRouters(dummyRouter.target)).to.equal(false);
    });

    it("Should revert proposeRouterChange with OwnableUnauthorizedAccount when non-owner calls", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await expect(
        feeRouter.connect(user).proposeRouterChange(contractRouter.target, true)
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should revert proposeRouterChange with InvalidRouterAddress when router is zero address", async function () {
      await expect(
        feeRouter.connect(owner).proposeRouterChange(ethers.ZeroAddress, true)
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });

    it("Should emit RouterChangeProposed event on propose", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      const tx = await feeRouter.connect(owner).proposeRouterChange(contractRouter.target, true);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const expectedTime = block.timestamp + ROUTER_ALLOWLIST_DELAY;

      await expect(tx)
        .to.emit(feeRouter, "RouterChangeProposed")
        .withArgs(contractRouter.target, true, expectedTime);
    });

    it("Should emit RouterAllowlistUpdated event on apply", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await feeRouter.connect(owner).proposeRouterChange(contractRouter.target, true);
      await ethers.provider.send("evm_increaseTime", [ROUTER_ALLOWLIST_DELAY]);
      await ethers.provider.send("evm_mine", []);

      await expect(feeRouter.connect(owner).applyRouterChange())
        .to.emit(feeRouter, "RouterAllowlistUpdated")
        .withArgs(contractRouter.target, true);
    });

    it("Should revert applyRouterChange with RouterTimelockNotExpired before delay", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await feeRouter.connect(owner).proposeRouterChange(contractRouter.target, true);

      // Try to apply immediately -- timelock not expired
      await expect(
        feeRouter.connect(owner).applyRouterChange()
      ).to.be.revertedWithCustomError(feeRouter, "RouterTimelockNotExpired");
    });

    it("Should revert applyRouterChange with NoPendingRouterChange when nothing proposed", async function () {
      await expect(
        feeRouter.connect(owner).applyRouterChange()
      ).to.be.revertedWithCustomError(feeRouter, "NoPendingRouterChange");
    });

    it("Should cancel a pending router change", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await feeRouter.connect(owner).proposeRouterChange(contractRouter.target, true);

      await expect(feeRouter.connect(owner).cancelRouterChange())
        .to.emit(feeRouter, "RouterChangeCancelled")
        .withArgs(contractRouter.target);

      // After cancel, applyRouterChange should revert
      await expect(
        feeRouter.connect(owner).applyRouterChange()
      ).to.be.revertedWithCustomError(feeRouter, "NoPendingRouterChange");

      // Router should NOT be allowlisted
      expect(await feeRouter.allowedRouters(contractRouter.target)).to.equal(false);
    });

    it("Should revert cancelRouterChange with NoPendingRouterChange when nothing proposed", async function () {
      await expect(
        feeRouter.connect(owner).cancelRouterChange()
      ).to.be.revertedWithCustomError(feeRouter, "NoPendingRouterChange");
    });

    it("Should revert applyRouterChange with OwnableUnauthorizedAccount when non-owner calls", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await feeRouter.connect(owner).proposeRouterChange(contractRouter.target, true);
      await ethers.provider.send("evm_increaseTime", [ROUTER_ALLOWLIST_DELAY]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        feeRouter.connect(user).applyRouterChange()
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should revert swap with RouterNotAllowed when router is not allowlisted", async function () {
      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      const unlisted = await MockDEXRouter.deploy(ethers.parseEther("1"));
      // Do NOT allowlist unlisted

      const block = await ethers.provider.getBlock("latest");
      const deadline = block.timestamp + 86400 * 365;

      const calldata = unlisted.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        TOTAL_AMOUNT
      ]);

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          unlisted.target,
          calldata,
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "RouterNotAllowed");
    });

    it("Should store pending router state correctly", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await feeRouter.connect(owner).proposeRouterChange(contractRouter.target, true);

      expect(await feeRouter.pendingRouter()).to.equal(contractRouter.target);
      expect(await feeRouter.pendingRouterAllowed()).to.equal(true);
      expect(await feeRouter.routerChangeTime()).to.be.gt(0);
    });

    it("Should clear pending state after apply", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const contractRouter = await MockERC20.deploy("Router", "RTR");

      await allowRouterViaTimelock(feeRouter, owner, contractRouter.target, true);

      expect(await feeRouter.pendingRouter()).to.equal(ethers.ZeroAddress);
      expect(await feeRouter.routerChangeTime()).to.equal(0);
    });

    it("Should return ROUTER_ALLOWLIST_DELAY of 12 hours", async function () {
      const delay = await feeRouter.ROUTER_ALLOWLIST_DELAY();
      expect(delay).to.equal(12 * 60 * 60); // 43200 seconds
    });
  });

  // ---------------------------------------------------------------------------
  // Fee Collector Timelock (proposeFeeCollector / applyFeeCollector)
  // ---------------------------------------------------------------------------

  describe("proposeFeeCollector / applyFeeCollector", function () {
    it("Should allow owner to propose a new fee collector", async function () {
      await feeRouter.connect(owner).proposeFeeCollector(other.address);
      expect(await feeRouter.pendingFeeCollector()).to.equal(other.address);
    });

    it("Should revert with InvalidFeeCollector when proposing zero address", async function () {
      await expect(
        feeRouter.connect(owner).proposeFeeCollector(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(feeRouter, "InvalidFeeCollector");
    });

    it("Should revert with OwnableUnauthorizedAccount when non-owner proposes", async function () {
      await expect(
        feeRouter.connect(user).proposeFeeCollector(other.address)
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should emit FeeCollectorProposed event with correct effectiveTime", async function () {
      const tx = await feeRouter.connect(owner).proposeFeeCollector(other.address);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const delay = await feeRouter.FEE_COLLECTOR_DELAY();

      await expect(tx)
        .to.emit(feeRouter, "FeeCollectorProposed")
        .withArgs(other.address, BigInt(block.timestamp) + delay);
    });

    it("Should revert applyFeeCollector with TimelockNotExpired before delay", async function () {
      await feeRouter.connect(owner).proposeFeeCollector(other.address);

      // Try to apply immediately — timelock hasn't elapsed
      await expect(
        feeRouter.connect(owner).applyFeeCollector()
      ).to.be.revertedWithCustomError(feeRouter, "TimelockNotExpired");
    });

    it("Should revert applyFeeCollector with NoPendingChange when nothing proposed", async function () {
      await expect(
        feeRouter.connect(owner).applyFeeCollector()
      ).to.be.revertedWithCustomError(feeRouter, "NoPendingChange");
    });

    it("Should apply fee collector after timelock delay", async function () {
      await feeRouter.connect(owner).proposeFeeCollector(other.address);

      // Advance time past the 24-hour delay
      const delay = await feeRouter.FEE_COLLECTOR_DELAY();
      await time.increase(delay);

      await feeRouter.connect(owner).applyFeeCollector();

      expect(await feeRouter.feeCollector()).to.equal(other.address);
      // Pending state should be cleared
      expect(await feeRouter.pendingFeeCollector()).to.equal(ethers.ZeroAddress);
      expect(await feeRouter.feeCollectorChangeTime()).to.equal(0);
    });

    it("Should emit FeeCollectorUpdated event when applied", async function () {
      await feeRouter.connect(owner).proposeFeeCollector(other.address);

      const delay = await feeRouter.FEE_COLLECTOR_DELAY();
      await time.increase(delay);

      await expect(feeRouter.connect(owner).applyFeeCollector())
        .to.emit(feeRouter, "FeeCollectorUpdated")
        .withArgs(feeCollector.address, other.address);
    });

    it("Should revert applyFeeCollector with OwnableUnauthorizedAccount when non-owner calls", async function () {
      await feeRouter.connect(owner).proposeFeeCollector(other.address);

      const delay = await feeRouter.FEE_COLLECTOR_DELAY();
      await time.increase(delay);

      await expect(
        feeRouter.connect(user).applyFeeCollector()
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });
  });

  // ---------------------------------------------------------------------------
  // Access Control — Ownable2Step
  // ---------------------------------------------------------------------------

  describe("Ownable2Step access control", function () {
    it("Should return the correct owner", async function () {
      expect(await feeRouter.owner()).to.equal(owner.address);
    });

    it("Should allow owner to initiate ownership transfer", async function () {
      await feeRouter.connect(owner).transferOwnership(other.address);
      expect(await feeRouter.pendingOwner()).to.equal(other.address);
      // Owner should still be original owner until accepted
      expect(await feeRouter.owner()).to.equal(owner.address);
    });

    it("Should allow pending owner to accept ownership", async function () {
      await feeRouter.connect(owner).transferOwnership(other.address);
      await feeRouter.connect(other).acceptOwnership();
      expect(await feeRouter.owner()).to.equal(other.address);
    });

    it("Should revert transferOwnership when called by non-owner", async function () {
      await expect(
        feeRouter.connect(user).transferOwnership(other.address)
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should revert acceptOwnership when called by wrong address", async function () {
      await feeRouter.connect(owner).transferOwnership(other.address);
      await expect(
        feeRouter.connect(user).acceptOwnership() // user is not the pending owner
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should revert renounceOwnership (always disabled)", async function () {
      await expect(
        feeRouter.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(feeRouter, "InvalidFeeCollector");
    });
  });

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  describe("Events", function () {
    let mockRouter;
    const SWAP_AMOUNT = ethers.parseEther("100");

    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    beforeEach(async function () {
      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      mockRouter = await MockDEXRouter.deploy(ethers.parseEther("1"));
      await allowRouterViaTimelock(feeRouter, owner, mockRouter.target, true);
      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);
    });

    it("Should emit SwapExecuted with correct parameters on zero-fee swap", async function () {
      const deadline = await farFutureDeadline();

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,
          0,
          mockRouter.target,
          calldata,
          0,
          deadline
        )
      )
        .to.emit(feeRouter, "SwapExecuted")
        .withArgs(
          user.address,
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,      // totalAmount (actualReceived)
          0,                // feeAmount
          SWAP_AMOUNT,      // netAmount
          mockRouter.target
        );
    });

    it("Should emit SwapExecuted with correct fee split parameters", async function () {
      const deadline = await farFutureDeadline();
      const feeAmount = ethers.parseEther("1"); // 1% of 100
      const netAmount = SWAP_AMOUNT - feeAmount;

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        netAmount
      ]);

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,
          feeAmount,
          mockRouter.target,
          calldata,
          0,
          deadline
        )
      )
        .to.emit(feeRouter, "SwapExecuted")
        .withArgs(
          user.address,
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,
          feeAmount,
          netAmount,
          mockRouter.target
        );
    });

    it("Should emit TokensRescued with correct amount", async function () {
      const rescueAmount = ethers.parseEther("25");
      await inputToken.mint(feeRouter.target, rescueAmount);

      await expect(feeRouter.connect(owner).rescueTokens(inputToken.target))
        .to.emit(feeRouter, "TokensRescued")
        .withArgs(inputToken.target, rescueAmount);
    });

    it("Should not emit TokensRescued when balance is zero", async function () {
      await expect(feeRouter.connect(owner).rescueTokens(inputToken.target))
        .to.not.emit(feeRouter, "TokensRescued");
    });
  });

  // ---------------------------------------------------------------------------
  // Router Address Validation
  // ---------------------------------------------------------------------------

  describe("swapWithFee — router address validation", function () {
    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    it("Should revert when router address equals inputToken", async function () {
      const deadline = await farFutureDeadline();

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          inputToken.target,        // router = inputToken
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });

    it("Should revert when router address equals outputToken", async function () {
      const deadline = await farFutureDeadline();

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          outputToken.target,       // router = outputToken
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });

    it("Should revert when router address is this contract", async function () {
      const deadline = await farFutureDeadline();

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          feeRouter.target,         // router = feeRouter itself
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });

    it("Should revert when router address is an EOA (no code)", async function () {
      const deadline = await farFutureDeadline();

      // Allowlist the EOA — it should still fail the code.length check
      await allowRouterViaTimelock(feeRouter, owner, other.address, true);

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          other.address,            // EOA with no code
          "0x",
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });
  });

  // ---------------------------------------------------------------------------
  // Constructor Edge Cases
  // ---------------------------------------------------------------------------

  describe("Constructor edge cases", function () {
    it("Should accept maxFeeBps at the upper bound (500 = 5%)", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      const router = await OmniFeeRouter.deploy(feeCollector.address, 500, ethers.ZeroAddress);
      expect(await router.maxFeeBps()).to.equal(500);
    });

    it("Should accept maxFeeBps at the lower bound (1)", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      const router = await OmniFeeRouter.deploy(feeCollector.address, 1, ethers.ZeroAddress);
      expect(await router.maxFeeBps()).to.equal(1);
    });

    it("Should set msg.sender as owner", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      const router = await OmniFeeRouter.deploy(feeCollector.address, 100, ethers.ZeroAddress);
      expect(await router.owner()).to.equal(owner.address);
    });

    it("Should accept a non-zero trusted forwarder address", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const forwarder = await MockERC20.deploy("Forwarder", "FWD");

      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      const router = await OmniFeeRouter.deploy(feeCollector.address, 100, forwarder.target);
      expect(router.target).to.be.properAddress;
    });

    it("Should initialize totalFeesCollected to zero", async function () {
      expect(await feeRouter.totalFeesCollected()).to.equal(0);
    });

    it("Should initialize pendingFeeCollector to zero address", async function () {
      expect(await feeRouter.pendingFeeCollector()).to.equal(ethers.ZeroAddress);
    });

    it("Should initialize feeCollectorChangeTime to zero", async function () {
      expect(await feeRouter.feeCollectorChangeTime()).to.equal(0);
    });
  });

  // ---------------------------------------------------------------------------
  // View Functions & Constants
  // ---------------------------------------------------------------------------

  describe("View functions and constants", function () {
    it("Should return FEE_COLLECTOR_DELAY of 24 hours", async function () {
      const delay = await feeRouter.FEE_COLLECTOR_DELAY();
      expect(delay).to.equal(24 * 60 * 60); // 86400 seconds
    });

    it("Should return MIN_SWAP_AMOUNT of 1e15", async function () {
      const minAmount = await feeRouter.MIN_SWAP_AMOUNT();
      expect(minAmount).to.equal(ethers.parseUnits("1", 15));
    });

    it("Should return correct maxFeeBps (immutable)", async function () {
      expect(await feeRouter.maxFeeBps()).to.equal(MAX_FEE_BPS);
    });

    it("Should report allowedRouters for known router", async function () {
      expect(await feeRouter.allowedRouters(dummyRouter.target)).to.equal(true);
    });

    it("Should report allowedRouters as false for unknown address", async function () {
      expect(await feeRouter.allowedRouters(other.address)).to.equal(false);
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens — Additional Coverage
  // ---------------------------------------------------------------------------

  describe("rescueTokens — additional coverage", function () {
    it("Should rescue a different token than the input token", async function () {
      const rescueAmount = ethers.parseEther("77");
      await outputToken.mint(feeRouter.target, rescueAmount);

      await feeRouter.connect(owner).rescueTokens(outputToken.target);

      const collectorBalance = await outputToken.balanceOf(feeCollector.address);
      expect(collectorBalance).to.equal(rescueAmount);
      expect(await outputToken.balanceOf(feeRouter.target)).to.equal(0);
    });

    it("Should rescue tokens to the updated fee collector", async function () {
      // Change fee collector via timelock
      await feeRouter.connect(owner).proposeFeeCollector(other.address);
      const delay = await feeRouter.FEE_COLLECTOR_DELAY();
      await time.increase(delay);
      await feeRouter.connect(owner).applyFeeCollector();

      const rescueAmount = ethers.parseEther("42");
      await inputToken.mint(feeRouter.target, rescueAmount);

      await feeRouter.connect(owner).rescueTokens(inputToken.target);

      // Tokens should go to the NEW fee collector
      const otherBalance = await inputToken.balanceOf(other.address);
      expect(otherBalance).to.equal(rescueAmount);
    });
  });

  // ---------------------------------------------------------------------------
  // Cumulative Fee Accounting
  // ---------------------------------------------------------------------------

  describe("totalFeesCollected — cumulative accounting", function () {
    let mockRouter;
    const SWAP_AMOUNT = ethers.parseEther("100");

    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    beforeEach(async function () {
      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      mockRouter = await MockDEXRouter.deploy(ethers.parseEther("1"));
      await allowRouterViaTimelock(feeRouter, owner, mockRouter.target, true);
    });

    it("Should accumulate fees across multiple swaps", async function () {
      const deadline = await farFutureDeadline();
      const feeAmount = ethers.parseEther("0.5"); // 0.5%
      const netAmount = SWAP_AMOUNT - feeAmount;

      // First swap
      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        netAmount
      ]);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      expect(await feeRouter.totalFeesCollected()).to.equal(feeAmount);

      // Second swap
      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        feeAmount,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      expect(await feeRouter.totalFeesCollected()).to.equal(feeAmount * 2n);
    });

    it("Should not increment totalFeesCollected on zero-fee swap", async function () {
      const deadline = await farFutureDeadline();

      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        0,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      expect(await feeRouter.totalFeesCollected()).to.equal(0);
    });
  });

  // ---------------------------------------------------------------------------
  // Pausable (M-02 Audit Fix)
  // ---------------------------------------------------------------------------

  describe("Pausable", function () {
    let mockRouter;
    const SWAP_AMOUNT = ethers.parseEther("100");

    async function farFutureDeadline() {
      const block = await ethers.provider.getBlock("latest");
      return block.timestamp + 86400 * 365;
    }

    beforeEach(async function () {
      const MockDEXRouter = await ethers.getContractFactory("MockDEXRouterForFeeRouter");
      mockRouter = await MockDEXRouter.deploy(ethers.parseEther("1"));
      await allowRouterViaTimelock(feeRouter, owner, mockRouter.target, true);
      await inputToken.mint(user.address, SWAP_AMOUNT);
      await inputToken.connect(user).approve(feeRouter.target, SWAP_AMOUNT);
    });

    it("Should allow owner to pause", async function () {
      await feeRouter.connect(owner).pause();
      expect(await feeRouter.paused()).to.equal(true);
    });

    it("Should allow owner to unpause", async function () {
      await feeRouter.connect(owner).pause();
      await feeRouter.connect(owner).unpause();
      expect(await feeRouter.paused()).to.equal(false);
    });

    it("Should revert pause when called by non-owner", async function () {
      await expect(
        feeRouter.connect(user).pause()
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should revert unpause when called by non-owner", async function () {
      await feeRouter.connect(owner).pause();
      await expect(
        feeRouter.connect(user).unpause()
      ).to.be.revertedWithCustomError(feeRouter, "OwnableUnauthorizedAccount");
    });

    it("Should revert swapWithFee when paused", async function () {
      const deadline = await farFutureDeadline();

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      await feeRouter.connect(owner).pause();

      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          SWAP_AMOUNT,
          0,
          mockRouter.target,
          calldata,
          0,
          deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "EnforcedPause");
    });

    it("Should allow swapWithFee after unpause", async function () {
      const deadline = await farFutureDeadline();

      const calldata = mockRouter.interface.encodeFunctionData("swap", [
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT
      ]);

      await feeRouter.connect(owner).pause();
      await feeRouter.connect(owner).unpause();

      // Should succeed after unpause
      await feeRouter.connect(user).swapWithFee(
        inputToken.target,
        outputToken.target,
        SWAP_AMOUNT,
        0,
        mockRouter.target,
        calldata,
        0,
        deadline
      );

      const userOutput = await outputToken.balanceOf(user.address);
      expect(userOutput).to.equal(SWAP_AMOUNT);
    });

    it("Should still allow rescueTokens when paused", async function () {
      const rescueAmount = ethers.parseEther("50");
      await inputToken.mint(feeRouter.target, rescueAmount);

      await feeRouter.connect(owner).pause();

      // rescueTokens should still work when paused
      await feeRouter.connect(owner).rescueTokens(inputToken.target);

      const collectorBalance = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalance).to.equal(rescueAmount);
    });

    it("Should still allow proposeRouterChange when paused", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const newRouter = await MockERC20.deploy("New Router", "NR");

      await feeRouter.connect(owner).pause();

      // proposeRouterChange should still work when paused
      await feeRouter.connect(owner).proposeRouterChange(newRouter.target, true);
      expect(await feeRouter.pendingRouter()).to.equal(newRouter.target);
    });
  });
});
