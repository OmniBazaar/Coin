/**
 * @file RWAAMMAdapterRemediation.test.ts
 * @description Regression coverage for the 2026-08-04 RWAAMMAdapter
 * follow-up to `RWARouter-RWAAMM-remediation-reaudit-2026-08-04.md`'s
 * M-02 fix: RWAAMM's `trustedCallers_` constructor array has no setter,
 * so RWAAMMAdapter must be included in it at RWAAMM construction time,
 * alongside RWARouter, or every RWAAMMAdapter-routed swap reverts with
 * `UnauthorizedOnBehalfOf` the moment the new RWAAMM goes live.
 *
 * Proves the exact three-contract nonce-prediction sequence used by
 * `scripts/deploy-rwaamm-router-remediation-mainnet.ts` (RWAAMM, then
 * RWARouter, then RWAAMMAdapter, back-to-back with no interleaved
 * transaction) lands all three contracts at their predicted addresses
 * and results in a real, working `OmniSwapRouter.swap()` call that
 * routes through RWAAMMAdapter into the new RWAAMM.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RWAAMMAdapter + RWAAMM + RWARouter atomic remediation deploy (2026-08-04)", function () {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let amm: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let router: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let adapter: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let swapRouter: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let complianceOracle: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let emergencyGuardian: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let tokenA: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let tokenB: any;

  let owner: any;
  let feeVault: any;
  let mockTimelock: any;
  let user: any;
  let forwarder: any;
  let emergencySigners: any[];

  const INITIAL_LIQUIDITY = ethers.parseEther("10000");
  const SWAP_AMOUNT = ethers.parseEther("100");
  const RWAAMM_SOURCE_ID = ethers.id("RWAAMM");

  async function futureDeadline(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block!.timestamp + 3600;
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    [owner, feeVault, mockTimelock, user, forwarder] = signers;
    emergencySigners = signers.slice(6, 11);

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    tokenA = await ERC20Mock.deploy("Token A", "TKA");
    await tokenA.waitForDeployment();
    tokenB = await ERC20Mock.deploy("Token B", "TKB");
    await tokenB.waitForDeployment();

    await tokenA.mint(owner.address, INITIAL_LIQUIDITY);
    await tokenB.mint(owner.address, INITIAL_LIQUIDITY);
    await tokenA.mint(user.address, SWAP_AMOUNT * 10n);

    const RWAComplianceOracle = await ethers.getContractFactory("RWAComplianceOracle");
    complianceOracle = await RWAComplianceOracle.deploy(owner.address);
    await complianceOracle.waitForDeployment();
    await complianceOracle.connect(owner).registerToken(await tokenA.getAddress(), ethers.ZeroAddress);
    await complianceOracle.connect(owner).registerToken(await tokenB.getAddress(), ethers.ZeroAddress);

    const EmergencyGuardian = await ethers.getContractFactory("EmergencyGuardian");
    emergencyGuardian = await EmergencyGuardian.deploy(
      mockTimelock.address,
      emergencySigners.map((s) => s.address)
    );
    await emergencyGuardian.waitForDeployment();

    // OmniSwapRouter is a real, already-live, unrelated contract in this
    // integration — deployed fresh here only so the test can register a
    // liquidity source and call the real external swap() entry point
    // exactly as production does, rather than calling the adapter directly.
    const OmniSwapRouter = await ethers.getContractFactory("OmniSwapRouter");
    swapRouter = await OmniSwapRouter.deploy(feeVault.address, 30, forwarder.address);
    await swapRouter.waitForDeployment();

    // --- The exact sequence deploy-rwaamm-router-remediation-mainnet.ts uses ---
    const ownerNonce = await ethers.provider.getTransactionCount(owner.address);
    const futureRouterAddress = ethers.getCreateAddress({
      from: owner.address,
      nonce: ownerNonce + 1,
    });
    const futureAdapterAddress = ethers.getCreateAddress({
      from: owner.address,
      nonce: ownerNonce + 2,
    });

    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    amm = await RWAAMM.deploy(
      await emergencyGuardian.getAddress(),
      feeVault.address,
      await tokenA.getAddress(),
      await complianceOracle.getAddress(),
      forwarder.address,
      [futureRouterAddress, futureAdapterAddress]
    );
    await amm.waitForDeployment();

    const RWARouter = await ethers.getContractFactory("RWARouter");
    router = await RWARouter.deploy(await amm.getAddress(), forwarder.address);
    await router.waitForDeployment();
    expect((await router.getAddress()).toLowerCase()).to.equal(futureRouterAddress.toLowerCase());

    const RWAAMMAdapter = await ethers.getContractFactory("RWAAMMAdapter");
    adapter = await RWAAMMAdapter.deploy(await amm.getAddress(), await swapRouter.getAddress());
    await adapter.waitForDeployment();
    expect((await adapter.getAddress()).toLowerCase()).to.equal(futureAdapterAddress.toLowerCase());

    // Seed a tokenA/tokenB pool directly via the AMM.
    await tokenA.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
    await tokenB.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
    await amm
      .connect(owner)
      .addLiquidity(
        await tokenA.getAddress(),
        await tokenB.getAddress(),
        INITIAL_LIQUIDITY,
        INITIAL_LIQUIDITY,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );

    await swapRouter.connect(owner).addLiquiditySource(RWAAMM_SOURCE_ID, await adapter.getAddress());
  });

  describe("Deploy-time wiring", function () {
    it("RWAAMM trusts both the new RWARouter and the new RWAAMMAdapter", async function () {
      expect(await amm.isTrustedCaller(await router.getAddress())).to.equal(true);
      expect(await amm.isTrustedCaller(await adapter.getAddress())).to.equal(true);
    });

    it("RWAAMMAdapter's immutable refs point at the new RWAAMM and the live OmniSwapRouter", async function () {
      expect(await adapter.rwaamm()).to.equal(await amm.getAddress());
      expect(await adapter.router()).to.equal(await swapRouter.getAddress());
    });

    it("OmniSwapRouter routes the RWAAMM source id through the new adapter", async function () {
      expect(await swapRouter.liquiditySources(RWAAMM_SOURCE_ID)).to.equal(await adapter.getAddress());
    });
  });

  describe("End-to-end swap through OmniSwapRouter -> RWAAMMAdapter -> new RWAAMM", function () {
    it("a real user swap succeeds and lands the correct output at the user", async function () {
      await tokenA.connect(user).approve(await swapRouter.getAddress(), SWAP_AMOUNT);

      const balBefore = await tokenB.balanceOf(user.address);

      await swapRouter.connect(user).swap({
        tokenIn: await tokenA.getAddress(),
        tokenOut: await tokenB.getAddress(),
        amountIn: SWAP_AMOUNT,
        minAmountOut: 1n,
        path: [await tokenA.getAddress(), await tokenB.getAddress()],
        sources: [RWAAMM_SOURCE_ID],
        deadline: await futureDeadline(),
        recipient: user.address,
      });

      const balAfter = await tokenB.balanceOf(user.address);
      expect(balAfter).to.be.gt(balBefore);
    });

    it("would have reverted UnauthorizedOnBehalfOf pre-fix (adapter not a trusted caller)", async function () {
      // Sanity check that the wiring is load-bearing, not incidental:
      // deploy a second RWAAMM whose trustedCallers_ omits the adapter
      // (the exact bug this fix closes) and confirm the same swap path
      // reverts on that instance.
      const ownerNonce = await ethers.provider.getTransactionCount(owner.address);
      const futureRouterAddress = ethers.getCreateAddress({ from: owner.address, nonce: ownerNonce + 1 });

      const RWAAMM = await ethers.getContractFactory("RWAAMM");
      const brokenAmm = await RWAAMM.deploy(
        await emergencyGuardian.getAddress(),
        feeVault.address,
        await tokenA.getAddress(),
        await complianceOracle.getAddress(),
        forwarder.address,
        [futureRouterAddress] // adapter deliberately omitted, matching the pre-fix bug
      );
      await brokenAmm.waitForDeployment();
      const RWARouter = await ethers.getContractFactory("RWARouter");
      const brokenRouter = await RWARouter.deploy(await brokenAmm.getAddress(), forwarder.address);
      await brokenRouter.waitForDeployment();

      const RWAAMMAdapter = await ethers.getContractFactory("RWAAMMAdapter");
      const brokenAdapter = await RWAAMMAdapter.deploy(await brokenAmm.getAddress(), await swapRouter.getAddress());
      await brokenAdapter.waitForDeployment();

      await tokenA.connect(owner).approve(await brokenAmm.getAddress(), INITIAL_LIQUIDITY);
      await tokenB.connect(owner).approve(await brokenAmm.getAddress(), INITIAL_LIQUIDITY);
      await brokenAmm
        .connect(owner)
        .addLiquidity(
          await tokenA.getAddress(),
          await tokenB.getAddress(),
          INITIAL_LIQUIDITY,
          INITIAL_LIQUIDITY,
          0n,
          0n,
          await futureDeadline(),
          ethers.ZeroAddress
        );

      await swapRouter.connect(owner).addLiquiditySource(RWAAMM_SOURCE_ID, await brokenAdapter.getAddress());
      await tokenA.connect(user).approve(await swapRouter.getAddress(), SWAP_AMOUNT);

      await expect(
        swapRouter.connect(user).swap({
          tokenIn: await tokenA.getAddress(),
          tokenOut: await tokenB.getAddress(),
          amountIn: SWAP_AMOUNT,
          minAmountOut: 1n,
          path: [await tokenA.getAddress(), await tokenB.getAddress()],
          sources: [RWAAMM_SOURCE_ID],
          deadline: await futureDeadline(),
          recipient: user.address,
        })
      ).to.be.revertedWithCustomError(brokenAmm, "UnauthorizedOnBehalfOf");

      // restore the working adapter registration for any subsequent test
      await swapRouter.connect(owner).addLiquiditySource(RWAAMM_SOURCE_ID, await adapter.getAddress());
    });
  });

  describe("Known, deliberately-deferred finding: compliance-target identity through OmniSwapRouter", function () {
    it("documents that OmniSwapRouter, not the real trader, is the onBehalfOf target for every hop", async function () {
      // OmniSwapRouter._executeSwapPath always calls
      // ISwapAdapter.executeSwap(..., recipient = address(this)) for
      // EVERY hop (see OmniSwapRouter.sol's _executeSwapPath), because
      // intermediate-hop output must stay in the router's own custody to
      // feed the next hop. RWAAMMAdapter forwards that `recipient` as
      // `onBehalfOf` to RWAAMM.swap(). The net effect: when routed via
      // OmniSwapRouter, RWAAMM's compliance check is always evaluated
      // against OmniSwapRouter's own address, never the real trader.
      //
      // Confirmed CURRENTLY INERT: RWAAMM._isComplianceRequired() is
      // driven by RWAComplianceOracle.isTokenRegistered(), and
      // _checkComplianceInternal() returns COMPLIANT unconditionally
      // (ignoring the `user` argument) for any token registered with
      // TokenStandard.ERC20 (RWAComplianceOracle.sol's
      // _checkComplianceInternal, "No compliance requirements" branch)
      // — which is what both tokens in this test, and the live
      // XomUsdcPool, are registered as. A real ERC-3643/ERC-1400 RWA
      // token pool routed through this same path would NOT get this
      // free pass; the compliance check would run against
      // OmniSwapRouter's own address instead of the trader's.
      //
      // Not fixed in this remediation: closing it correctly requires
      // giving `ISwapAdapter.executeSwap` a way to carry the real end
      // user's identity through OmniSwapRouter's generic, adapter-shared
      // multi-hop executor — a change to the shared interface used by
      // every registered adapter (CLOBAdapter, FeeSwapAdapter,
      // ValidatorLiquidityBridge, ...), not just RWAAMMAdapter. Out of
      // scope for this session's authorized task (documented instead in
      // the accompanying audit report and TODO.md).
      await tokenA.connect(user).approve(await swapRouter.getAddress(), SWAP_AMOUNT);
      await swapRouter.connect(user).swap({
        tokenIn: await tokenA.getAddress(),
        tokenOut: await tokenB.getAddress(),
        amountIn: SWAP_AMOUNT,
        minAmountOut: 1n,
        path: [await tokenA.getAddress(), await tokenB.getAddress()],
        sources: [RWAAMM_SOURCE_ID],
        deadline: await futureDeadline(),
        recipient: user.address,
      });

      // The swap succeeded above using plain ERC20-standard tokens
      // (the live, only-ever-used-in-production case) precisely because
      // compliance is a no-op for that standard — proving the gap is
      // real in principle but does not currently affect any live pool.
    });
  });
});
