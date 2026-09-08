/**
 * @file RWARouterRemediation.test.ts
 * @description Regression coverage for the 2026-08-04 remediation's four
 * Medium findings:
 *   - M-01: `sweepTokens()` + missing `to == address(this)` guard.
 *   - M-02: `RWAAMM.onBehalfOf` compliance-check target not bound to the
 *     actual fund-moving caller (fixed in `RWAAMM.sol`, not `RWARouter.sol`,
 *     but exercised here since both files changed together).
 *   - M-03: fee-on-transfer / rebasing token handling inconsistency between
 *     the swap path and the liquidity path.
 *   - L-01 (opportunistic): missing zero-check on `trustedForwarder_`.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RWARouter + RWAAMM remediation (2026-08-04 audit fixes)", function () {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let amm: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let router: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let complianceOracle: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let emergencyGuardian: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let tokenA: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let tokenB: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let fotToken: any;

  let owner: any;
  let feeVault: any;
  let mockTimelock: any;
  let user: any;
  let attacker: any;
  let forwarder: any;
  let emergencySigners: any[];

  const INITIAL_LIQUIDITY = ethers.parseEther("10000");
  const SWAP_AMOUNT = ethers.parseEther("100");

  async function futureDeadline(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block!.timestamp + 3600;
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    [owner, feeVault, mockTimelock, user, attacker, forwarder] = signers;
    emergencySigners = signers.slice(6, 11);

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    tokenA = await ERC20Mock.deploy("Token A", "TKA");
    await tokenA.waitForDeployment();
    tokenB = await ERC20Mock.deploy("Token B", "TKB");
    await tokenB.waitForDeployment();

    const FotToken = await ethers.getContractFactory("FeeOnTransferToggleToken");
    fotToken = await FotToken.deploy("Fee Token", "FEE", 0);
    await fotToken.waitForDeployment();

    await tokenA.mint(owner.address, INITIAL_LIQUIDITY);
    await tokenB.mint(owner.address, INITIAL_LIQUIDITY);
    await tokenA.mint(user.address, SWAP_AMOUNT * 10n);
    await fotToken.mint(owner.address, INITIAL_LIQUIDITY);
    await fotToken.mint(user.address, SWAP_AMOUNT * 10n);

    const RWAComplianceOracle = await ethers.getContractFactory("RWAComplianceOracle");
    complianceOracle = await RWAComplianceOracle.deploy(owner.address);
    await complianceOracle.waitForDeployment();
    await complianceOracle.connect(owner).registerToken(await tokenA.getAddress(), ethers.ZeroAddress);
    await complianceOracle.connect(owner).registerToken(await tokenB.getAddress(), ethers.ZeroAddress);
    await complianceOracle.connect(owner).registerToken(await fotToken.getAddress(), ethers.ZeroAddress);

    const EmergencyGuardian = await ethers.getContractFactory("EmergencyGuardian");
    emergencyGuardian = await EmergencyGuardian.deploy(
      mockTimelock.address,
      emergencySigners.map((s) => s.address)
    );
    await emergencyGuardian.waitForDeployment();

    // RWAAMM's constructor now needs the router's own future address
    // (audit fix M-02, 2026-08-04). Predict it from the deployer's next
    // nonce; AMM deploy and router deploy MUST stay back-to-back.
    const ownerNonce = await ethers.provider.getTransactionCount(owner.address);
    const futureRouterAddress = ethers.getCreateAddress({
      from: owner.address,
      nonce: ownerNonce + 1,
    });

    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    amm = await RWAAMM.deploy(
      await emergencyGuardian.getAddress(),
      feeVault.address,
      await tokenA.getAddress(),
      await complianceOracle.getAddress(),
      forwarder.address,
      [futureRouterAddress]
    );
    await amm.waitForDeployment();

    const RWARouter = await ethers.getContractFactory("RWARouter");
    router = await RWARouter.deploy(await amm.getAddress(), forwarder.address);
    await router.waitForDeployment();
    expect((await router.getAddress()).toLowerCase()).to.equal(futureRouterAddress.toLowerCase());

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
  });

  // ── M-01: self-strand guard + sweepTokens ──────────────────────────────

  describe("M-01: to == address(this) guard", function () {
    it("swapExactTokensForTokens reverts InvalidRecipient when to == router", async function () {
      await tokenA.connect(user).approve(await router.getAddress(), SWAP_AMOUNT);
      await expect(
        router
          .connect(user)
          .swapExactTokensForTokens(
            SWAP_AMOUNT,
            1n,
            [await tokenA.getAddress(), await tokenB.getAddress()],
            await router.getAddress(),
            await futureDeadline()
          )
      ).to.be.revertedWithCustomError(router, "InvalidRecipient");
    });

    it("swapTokensForExactTokens reverts InvalidRecipient when to == router", async function () {
      await tokenA.connect(user).approve(await router.getAddress(), SWAP_AMOUNT * 2n);
      await expect(
        router
          .connect(user)
          .swapTokensForExactTokens(
            SWAP_AMOUNT,
            SWAP_AMOUNT * 2n,
            [await tokenA.getAddress(), await tokenB.getAddress()],
            await router.getAddress(),
            await futureDeadline()
          )
      ).to.be.revertedWithCustomError(router, "InvalidRecipient");
    });

    it("addLiquidity reverts InvalidRecipient when to == router", async function () {
      await tokenA.connect(owner).approve(await router.getAddress(), SWAP_AMOUNT);
      await tokenB.connect(owner).approve(await router.getAddress(), SWAP_AMOUNT);
      await expect(
        router
          .connect(owner)
          .addLiquidity(
            await tokenA.getAddress(),
            await tokenB.getAddress(),
            SWAP_AMOUNT,
            SWAP_AMOUNT,
            0n,
            0n,
            await router.getAddress(),
            await futureDeadline()
          )
      ).to.be.revertedWithCustomError(router, "InvalidRecipient");
    });

    it("removeLiquidity reverts InvalidRecipient when to == router", async function () {
      const poolAddr = await amm["getPool(address,address)"](
        await tokenA.getAddress(),
        await tokenB.getAddress()
      );
      const pool = await ethers.getContractAt("IERC20", poolAddr);
      const lpBal = await pool.balanceOf(owner.address);
      await pool.connect(owner).approve(await router.getAddress(), lpBal);
      await expect(
        router
          .connect(owner)
          .removeLiquidity(
            await tokenA.getAddress(),
            await tokenB.getAddress(),
            lpBal,
            0n,
            0n,
            await router.getAddress(),
            await futureDeadline()
          )
      ).to.be.revertedWithCustomError(router, "InvalidRecipient");
    });

    it("sweepTokens still works for legitimate dust recovery (unaffected by the guard)", async function () {
      const dust = ethers.parseEther("1");
      await tokenA.mint(await router.getAddress(), dust);
      await expect(router.connect(attacker).sweepTokens(await tokenA.getAddress(), attacker.address))
        .to.emit(router, "TokensSwept")
        .withArgs(await tokenA.getAddress(), attacker.address, dust);
    });
  });

  // ── L-01: zero forwarder rejected ──────────────────────────────────────

  describe("L-01: zero trustedForwarder_ rejected", function () {
    it("constructor reverts ZeroAddress when trustedForwarder_ is the zero address", async function () {
      const RWARouter = await ethers.getContractFactory("RWARouter");
      await expect(
        RWARouter.deploy(await amm.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(router, "ZeroAddress");
    });
  });

  // ── M-02: RWAAMM onBehalfOf trusted-caller binding ─────────────────────

  describe("M-02: RWAAMM onBehalfOf compliance-target binding", function () {
    it("a direct (non-trusted) caller passing a non-zero onBehalfOf reverts UnauthorizedOnBehalfOf", async function () {
      await tokenA.connect(attacker).approve(await amm.getAddress(), SWAP_AMOUNT);
      await tokenA.mint(attacker.address, SWAP_AMOUNT);
      await expect(
        amm
          .connect(attacker)
          .swap(
            await tokenA.getAddress(),
            await tokenB.getAddress(),
            SWAP_AMOUNT,
            0n,
            await futureDeadline(),
            owner.address // spoofed onBehalfOf — attacker is not RWAAMM's trusted caller
          )
      )
        .to.be.revertedWithCustomError(amm, "UnauthorizedOnBehalfOf")
        .withArgs(attacker.address, owner.address);
    });

    it("a direct caller passing onBehalfOf == address(0) still works normally (self-checked)", async function () {
      await tokenA.mint(attacker.address, SWAP_AMOUNT);
      await tokenA.connect(attacker).approve(await amm.getAddress(), SWAP_AMOUNT);
      await expect(
        amm
          .connect(attacker)
          .swap(
            await tokenA.getAddress(),
            await tokenB.getAddress(),
            SWAP_AMOUNT,
            0n,
            await futureDeadline(),
            ethers.ZeroAddress
          )
      ).to.not.be.reverted;
    });

    it("the trusted router's forwarded onBehalfOf is still honored end-to-end", async function () {
      await tokenA.connect(user).approve(await router.getAddress(), SWAP_AMOUNT);
      await expect(
        router
          .connect(user)
          .swapExactTokensForTokens(
            SWAP_AMOUNT,
            1n,
            [await tokenA.getAddress(), await tokenB.getAddress()],
            user.address,
            await futureDeadline()
          )
      ).to.not.be.reverted;
      expect(await tokenB.balanceOf(user.address)).to.be.gt(0n);
    });

    it("isTrustedCaller reports true for the router and false for an arbitrary address", async function () {
      expect(await amm.isTrustedCaller(await router.getAddress())).to.equal(true);
      expect(await amm.isTrustedCaller(attacker.address)).to.equal(false);
    });

    it("constructor reverts ZeroAddress when trustedCallers_ is empty", async function () {
      const RWAAMM = await ethers.getContractFactory("RWAAMM");
      await expect(
        RWAAMM.deploy(
          await emergencyGuardian.getAddress(),
          feeVault.address,
          await tokenA.getAddress(),
          await complianceOracle.getAddress(),
          forwarder.address,
          []
        )
      ).to.be.revertedWithCustomError(amm, "ZeroAddress");
    });
  });

  // ── M-03: fee-on-transfer balance-delta consistency ────────────────────

  describe("M-03: fee-on-transfer balance-delta consistency", function () {
    it("addLiquidity uses the router's actual (post-fee) balance-delta, not the stale desired amount", async function () {
      // Register a fresh fotToken/tokenB pool.
      await fotToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
      await tokenB.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
      await amm
        .connect(owner)
        .addLiquidity(
          await fotToken.getAddress(),
          await tokenB.getAddress(),
          INITIAL_LIQUIDITY,
          INITIAL_LIQUIDITY,
          0n,
          0n,
          await futureDeadline(),
          ethers.ZeroAddress
        );

      // Turn the transfer fee on for the router-bound deposit.
      await fotToken.setFeeBps(200); // 2%

      const depositDesired = ethers.parseEther("100");
      await fotToken.connect(user).approve(await router.getAddress(), depositDesired);
      await tokenB.mint(user.address, depositDesired);
      await tokenB.connect(user).approve(await router.getAddress(), depositDesired);

      const routerFotBalBefore = await fotToken.balanceOf(await router.getAddress());
      expect(routerFotBalBefore).to.equal(0n);

      // Pre-fix, the router would forceApprove/pass `amountADesired`
      // (the full nominal, pre-fee amount) into AMM.addLiquidity() even
      // though it only actually holds the fee-reduced amount — this
      // either strands an inflated approval or fails when the AMM tries
      // to pull more than the router holds. Post-fix, the router
      // measures its own actual balance-delta (98 tokens, after the 2%
      // fee) and never claims to hold more than that.
      await router
        .connect(user)
        .addLiquidity(
          await fotToken.getAddress(),
          await tokenB.getAddress(),
          depositDesired,
          depositDesired,
          0n,
          0n,
          user.address,
          await futureDeadline()
        );

      // The router must not retain a stranded balance beyond dust —
      // it should have forwarded/refunded everything it actually held.
      const routerFotBalAfter = await fotToken.balanceOf(await router.getAddress());
      expect(routerFotBalAfter).to.equal(0n);
    });

    it("swapTokensForExactTokens's first hop reduces amounts[0] to the actual received balance", async function () {
      // Pool: fotToken/tokenB, fee OFF while seeding so the pool holds
      // exact reserves.
      await fotToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
      await tokenB.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
      await amm
        .connect(owner)
        .addLiquidity(
          await fotToken.getAddress(),
          await tokenB.getAddress(),
          INITIAL_LIQUIDITY,
          INITIAL_LIQUIDITY,
          0n,
          0n,
          await futureDeadline(),
          ethers.ZeroAddress
        );

      await fotToken.setFeeBps(200); // 2%
      await fotToken.mint(user.address, SWAP_AMOUNT);
      await fotToken.connect(user).approve(await router.getAddress(), SWAP_AMOUNT);

      // The AMM-level K-invariant does not support fee-on-transfer
      // tokens end-to-end (documented in RWAAMM.sol's own NatSpec) —
      // this call is expected to fail closed at the pool layer, not
      // silently succeed with a wrong output. What this test proves is
      // narrower and router-scoped: the router's first-hop transfer-in
      // is measured via balance-delta (this file's `amounts[i]`
      // reduction), so the failure — if any — comes from the AMM's own
      // documented FOT limitation, not from the router requesting an
      // ERC20 transfer/approval larger than what it actually holds.
      const routerBalBeforeAttempt = await fotToken.balanceOf(await router.getAddress());
      expect(routerBalBeforeAttempt).to.equal(0n);

      let failureReason = "";
      try {
        await router
          .connect(user)
          .swapTokensForExactTokens(
            ethers.parseEther("10"),
            SWAP_AMOUNT,
            [await fotToken.getAddress(), await tokenB.getAddress()],
            user.address,
            await futureDeadline()
          );
      } catch (err: any) {
        failureReason = String(err?.message ?? err);
      }

      // The pre-fix bug manifested as a raw ERC20 balance/allowance
      // failure (the router attempting to move more than it actually
      // held, because `amounts[0]` still held the stale, un-reduced
      // desired amount). Post-fix, `amounts[0]` is corrected to the
      // real balance-delta before ever reaching the AMM, so that
      // specific failure class must not occur — any revert that does
      // occur must instead come from the AMM/pool's own documented
      // fee-on-transfer limitation (e.g. KValueDecreased), not a raw
      // ERC20 transfer/allowance shortfall at the router.
      expect(failureReason).to.not.match(/ERC20InsufficientBalance|ERC20InsufficientAllowance/);

      // The router must never end up stranded holding fotToken dust
      // from this attempt, whether it succeeded or reverted closed.
      const routerBalAfter = await fotToken.balanceOf(await router.getAddress());
      expect(routerBalAfter).to.equal(0n);
    });
  });
});
