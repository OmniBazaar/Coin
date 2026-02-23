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

    // Deploy OmniFeeRouter with valid parameters
    const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
    feeRouter = await OmniFeeRouter.deploy(feeCollector.address, MAX_FEE_BPS);

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
      const router = await OmniFeeRouter.deploy(feeCollector.address, 200);
      expect(router.target).to.be.properAddress;
    });

    it("Should revert with InvalidFeeCollector when feeCollector is zero address", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      await expect(
        OmniFeeRouter.deploy(ethers.ZeroAddress, MAX_FEE_BPS)
      ).to.be.revertedWithCustomError(
        { interface: OmniFeeRouter.interface },
        "InvalidFeeCollector"
      );
    });

    it("Should revert with FeeExceedsCap when maxFeeBps is 0", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      await expect(
        OmniFeeRouter.deploy(feeCollector.address, 0)
      ).to.be.revertedWithCustomError(
        { interface: OmniFeeRouter.interface },
        "FeeExceedsCap"
      );
    });

    it("Should revert with FeeExceedsCap when maxFeeBps exceeds 500", async function () {
      const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
      await expect(
        OmniFeeRouter.deploy(feeCollector.address, 501)
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
    // Far-future deadline (M-01: deadline parameter added for MEV protection)
    const FAR_FUTURE = Math.floor(Date.now() / 1000) + 86400 * 365;

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
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          0,                        // totalAmount = 0
          0,                        // feeAmount
          dummyRouter.target,       // routerAddress (contract with code)
          "0x",                     // routerCalldata
          0,                        // minOutput
          FAR_FUTURE                // deadline
        )
      ).to.be.revertedWithCustomError(feeRouter, "ZeroAmount");
    });

    it("Should revert with InvalidTokenAddress when inputToken is zero address", async function () {
      await expect(
        feeRouter.connect(user).swapWithFee(
          ethers.ZeroAddress,       // inputToken = zero
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          other.address,
          "0x",
          0,
          FAR_FUTURE
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidTokenAddress");
    });

    it("Should revert with InvalidTokenAddress when outputToken is zero address", async function () {
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          ethers.ZeroAddress,       // outputToken = zero
          TOTAL_AMOUNT,
          0,
          other.address,
          "0x",
          0,
          FAR_FUTURE
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidTokenAddress");
    });

    it("Should revert with InvalidRouterAddress when routerAddress is zero address", async function () {
      await expect(
        feeRouter.connect(user).swapWithFee(
          inputToken.target,
          outputToken.target,
          TOTAL_AMOUNT,
          0,
          ethers.ZeroAddress,       // routerAddress = zero
          "0x",
          0,
          FAR_FUTURE
        )
      ).to.be.revertedWithCustomError(feeRouter, "InvalidRouterAddress");
    });

    it("Should revert with FeeExceedsTotal when feeAmount > totalAmount", async function () {
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
          FAR_FUTURE
        )
      ).to.be.revertedWithCustomError(feeRouter, "FeeExceedsTotal");
    });

    it("Should revert with FeeExceedsCap when fee exceeds maxFeeBps cap", async function () {
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
          FAR_FUTURE
        )
      ).to.be.revertedWithCustomError(feeRouter, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens
  // ---------------------------------------------------------------------------

  describe("rescueTokens", function () {
    it("Should allow feeCollector to rescue tokens stuck in the contract", async function () {
      // Send some tokens directly to the feeRouter contract (simulating stuck tokens)
      const rescueAmount = ethers.parseEther("50");
      await inputToken.mint(feeRouter.target, rescueAmount);

      const collectorBalanceBefore = await inputToken.balanceOf(feeCollector.address);

      await feeRouter.connect(feeCollector).rescueTokens(inputToken.target);

      const collectorBalanceAfter = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalanceAfter - collectorBalanceBefore).to.equal(rescueAmount);

      // Contract balance should be zero after rescue
      expect(await inputToken.balanceOf(feeRouter.target)).to.equal(0);
    });

    it("Should revert with InvalidFeeCollector when called by non-feeCollector", async function () {
      // Send some tokens to the contract so there is something to rescue
      await inputToken.mint(feeRouter.target, ethers.parseEther("50"));

      await expect(
        feeRouter.connect(user).rescueTokens(inputToken.target)
      ).to.be.revertedWithCustomError(feeRouter, "InvalidFeeCollector");
    });

    it("Should succeed silently when no tokens are stuck", async function () {
      // Contract has zero balance — rescue should not revert
      const collectorBalanceBefore = await inputToken.balanceOf(feeCollector.address);
      await feeRouter.connect(feeCollector).rescueTokens(inputToken.target);
      const collectorBalanceAfter = await inputToken.balanceOf(feeCollector.address);
      expect(collectorBalanceAfter).to.equal(collectorBalanceBefore);
    });
  });
});
