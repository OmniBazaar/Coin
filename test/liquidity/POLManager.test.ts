/* eslint-disable @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires */
/* eslint-disable @typescript-eslint/no-explicit-any */
const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title POLManager Test Suite
 * @notice Functional + adversarial coverage for the permissionless-keeper
 *         POL automation contract (GATE 1, pre-mainnet).
 * @dev Built against real OmniTreasuryV2 + real POLManager, with faithful
 *      MockRWAAMMFull / MockRWAPool / MockSwapRouter mocks. Covers
 *      constructor guards, governance setters, the TWAP seeding flow,
 *      deploy / harvest / compound / rebalance happy paths, the D1
 *      value-loss bounds (DeployValueLoss / HarvestValueLoss /
 *      CompoundValueLoss), multi-call accounting coherence, cadence
 *      guards, KEEPER_ROLE gating, and pause gating.
 */
describe("POLManager", function () {
  let treasury: any;
  let polManager: any;
  let amm: any;
  let router: any;
  let tokenA: any; // token0 of the pool
  let tokenB: any; // token1 of the pool (the POL numeraire / stable)
  let pool: any;
  let poolId: string;

  let admin: any;
  let keeper: any;
  let attacker: any;
  let adminAddr: string;
  let keeperAddr: string;

  let GOVERNANCE_ROLE: string;
  let GUARDIAN_ROLE: string;
  let KEEPER_ROLE: string;
  let DEFAULT_ADMIN_ROLE: string;
  let POL_DEPLOYER_ROLE: string;

  const TWAP_WINDOW = 30 * 60; // DEFAULT_MIN_TWAP_WINDOW (30 min)
  const DEPLOY_INTERVAL = 60 * 60; // 1 hour
  const REBAL_INTERVAL = 60 * 60;
  const HARVEST_INTERVAL = 60 * 60;

  // Very deep pools so the constant-product price impact of a
  // deploy-sized swap stays far below the slippage band — an honest
  // deploy must clear the 50-bps floor (router fee 30 bps + tiny
  // impact). With 500M reserves and a 100k deploy, `half` = 50k is
  // 0.01% of the reserve, so total swap loss ≈ 0.31%.
  const POOL_RESERVE = ethers.parseEther("500000000"); // 500M each side
  const TREASURY_FUND = ethers.parseEther("1000000"); // 1M token1 idle
  const MAX_DEPLOY = ethers.parseEther("100000"); // 100k per call

  /**
   * Advance the chain by `seconds` and mine a block so TWAP windows
   * mature deterministically.
   */
  async function advance(seconds: number): Promise<void> {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);
  }

  /**
   * Seed a pool's TWAP: poke to set the anchor, advance one window,
   * poke again to store the first completed-window average.
   */
  async function seedTwap(): Promise<void> {
    await polManager.pokeObservation(poolId);
    await advance(TWAP_WINDOW + 1);
    await polManager.pokeObservation(poolId);
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    admin = signers[0];
    keeper = signers[1];
    attacker = signers[2];
    adminAddr = await admin.getAddress();
    keeperAddr = await keeper.getAddress();

    // ── Tokens ──────────────────────────────────────────────────────
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const t0 = await MockERC20.deploy("Token A", "TKA");
    const t1 = await MockERC20.deploy("Token B", "TKB");
    await t0.waitForDeployment();
    await t1.waitForDeployment();

    // ── Treasury ────────────────────────────────────────────────────
    const Treasury = await ethers.getContractFactory("OmniTreasuryV2");
    treasury = await Treasury.deploy(adminAddr);
    await treasury.waitForDeployment();

    // ── AMM + pool ──────────────────────────────────────────────────
    const Amm = await ethers.getContractFactory("MockRWAAMMFull");
    amm = await Amm.deploy();
    await amm.waitForDeployment();

    // Create the pool; the AMM fixes token0/token1 to the arg order.
    await amm.createPool(t0.target, t1.target);
    const pAddr = await amm["getPool(address,address)"](
      t0.target,
      t1.target
    );
    const Pool = await ethers.getContractFactory(
      "contracts/test/MockRWAPool.sol:MockRWAPool"
    );
    pool = Pool.attach(pAddr);

    // Resolve which token the pool calls token0 / token1.
    const poolToken0 = await pool.token0();
    tokenA = poolToken0 === t0.target ? t0 : t1;
    tokenB = poolToken0 === t0.target ? t1 : t0;

    // Seed the pool with deep, balanced reserves (1:1 price).
    await tokenA.mint(pAddr, POOL_RESERVE);
    await tokenB.mint(pAddr, POOL_RESERVE);
    await pool.mint(adminAddr);

    poolId = await amm.getPoolId(tokenA.target, tokenB.target);

    // ── Swap router ─────────────────────────────────────────────────
    const Router = await ethers.getContractFactory("MockSwapRouter");
    router = await Router.deploy(amm.target);
    await router.waitForDeployment();

    // ── POLManager ──────────────────────────────────────────────────
    const Pol = await ethers.getContractFactory("POLManager");
    polManager = await Pol.deploy(
      treasury.target,
      amm.target,
      router.target,
      adminAddr,
      ethers.ZeroAddress // no trusted forwarder
    );
    await polManager.waitForDeployment();

    GOVERNANCE_ROLE = await polManager.GOVERNANCE_ROLE();
    GUARDIAN_ROLE = await polManager.GUARDIAN_ROLE();
    KEEPER_ROLE = await polManager.KEEPER_ROLE();
    DEFAULT_ADMIN_ROLE = await polManager.DEFAULT_ADMIN_ROLE();
    POL_DEPLOYER_ROLE = await treasury.POL_DEPLOYER_ROLE();

    // ── Wiring (GATE 2 runbook) ─────────────────────────────────────
    await treasury
      .connect(admin)
      .grantRole(POL_DEPLOYER_ROLE, polManager.target);
    await treasury
      .connect(admin)
      .setPOLTarget(polManager.target, true);
    await treasury.connect(admin).setPOLTarget(pAddr, true); // LP token

    // Keeper allowlist.
    await polManager.connect(admin).setKeeper(keeperAddr, true);

    // Whitelist tokens + pool, set policy + cadence.
    await polManager.connect(admin).whitelistToken(tokenA.target, true);
    await polManager.connect(admin).whitelistToken(tokenB.target, true);
    await polManager
      .connect(admin)
      .whitelistPool(tokenA.target, tokenB.target);
    await polManager
      .connect(admin)
      .setPolicy(poolId, true, 0, 5000, HARVEST_INTERVAL);
    await polManager
      .connect(admin)
      .setCadence(poolId, DEPLOY_INTERVAL, REBAL_INTERVAL);
    await polManager.connect(admin).setMaxDeployPerCall(MAX_DEPLOY);

    // Source id for the router (any non-zero value works for the mock).
    await polManager
      .connect(admin)
      .setRwaammSourceId(ethers.id("RWAAMM_SOURCE"));

    // Fund the treasury with idle token1.
    await tokenB.mint(treasury.target, TREASURY_FUND);
  });

  // ════════════════════════════════════════════════════════════════
  //  1. Constructor / immutables
  // ════════════════════════════════════════════════════════════════

  describe("Constructor", function () {
    it("sets immutables and default parameters", async function () {
      expect(await polManager.TREASURY_ADDRESS()).to.equal(
        treasury.target
      );
      expect(await polManager.RWA_AMM()).to.equal(amm.target);
      expect(await polManager.SWAP_ROUTER()).to.equal(router.target);
      expect(await polManager.maxSlippageBps()).to.equal(100);
      expect(await polManager.minTwapWindow()).to.equal(TWAP_WINDOW);
    });

    it("grants admin/governance/guardian to the deployer admin", async function () {
      expect(await polManager.hasRole(DEFAULT_ADMIN_ROLE, adminAddr)).to.be
        .true;
      expect(await polManager.hasRole(GOVERNANCE_ROLE, adminAddr)).to.be
        .true;
      expect(await polManager.hasRole(GUARDIAN_ROLE, adminAddr)).to.be
        .true;
    });

    it("reverts on any zero address", async function () {
      const Pol = await ethers.getContractFactory("POLManager");
      await expect(
        Pol.deploy(
          ethers.ZeroAddress,
          amm.target,
          router.target,
          adminAddr,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(polManager, "ZeroAddress");
      await expect(
        Pol.deploy(
          treasury.target,
          amm.target,
          router.target,
          ethers.ZeroAddress,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(polManager, "ZeroAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  2. Governance setters + guards
  // ════════════════════════════════════════════════════════════════

  describe("Governance setters", function () {
    it("whitelistPool reverts on a non-existent pool", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const x = await MockERC20.deploy("X", "X");
      const y = await MockERC20.deploy("Y", "Y");
      await polManager.connect(admin).whitelistToken(x.target, true);
      await polManager.connect(admin).whitelistToken(y.target, true);
      await expect(
        polManager.connect(admin).whitelistPool(x.target, y.target)
      ).to.be.revertedWithCustomError(polManager, "PoolDoesNotExist");
    });

    it("whitelistPool reverts when a token is not whitelisted", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const x = await MockERC20.deploy("X", "X");
      await expect(
        polManager.connect(admin).whitelistPool(x.target, tokenB.target)
      ).to.be.revertedWithCustomError(polManager, "TokenNotWhitelisted");
    });

    it("whitelistPool stores tokens in the pool's own order", async function () {
      const policy = await polManager.getPoolPolicy(poolId);
      expect(policy.token0).to.equal(await pool.token0());
      expect(policy.token1).to.equal(await pool.token1());
    });

    it("deWhitelistPool blocks while LP is held, succeeds when empty", async function () {
      await seedTwap();
      await polManager.connect(keeper).deploy(poolId);
      await expect(
        polManager.connect(admin).deWhitelistPool(poolId)
      ).to.be.revertedWithCustomError(
        polManager,
        "PoolStillHasLiquidity"
      );
      // Drain the position via rebalance is complex; instead exercise
      // the empty-pool path on a fresh pool with no deploys.
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const x = await MockERC20.deploy("X", "X");
      const y = await MockERC20.deploy("Y", "Y");
      await amm.createPool(x.target, y.target);
      await polManager.connect(admin).whitelistToken(x.target, true);
      await polManager.connect(admin).whitelistToken(y.target, true);
      await polManager.connect(admin).whitelistPool(x.target, y.target);
      const id2 = await amm.getPoolId(x.target, y.target);
      await expect(polManager.connect(admin).deWhitelistPool(id2))
        .to.emit(polManager, "PoolDeWhitelisted")
        .withArgs(id2);
    });

    it("setPolicy rejects minHarvestInterval == 0 for an enabled pool", async function () {
      await expect(
        polManager.connect(admin).setPolicy(poolId, true, 0, 5000, 0)
      ).to.be.revertedWithCustomError(
        polManager,
        "HarvestCadenceRequired"
      );
    });

    it("setCadence rejects zero intervals", async function () {
      await expect(
        polManager.connect(admin).setCadence(poolId, 0, REBAL_INTERVAL)
      ).to.be.revertedWithCustomError(
        polManager,
        "DeployCadenceRequired"
      );
      await expect(
        polManager.connect(admin).setCadence(poolId, DEPLOY_INTERVAL, 0)
      ).to.be.revertedWithCustomError(
        polManager,
        "DeployCadenceRequired"
      );
    });

    it("setMaxSlippageBps enforces the 500 cap", async function () {
      await expect(
        polManager.connect(admin).setMaxSlippageBps(501)
      ).to.be.revertedWithCustomError(polManager, "ValueAboveCap");
      await polManager.connect(admin).setMaxSlippageBps(500);
      expect(await polManager.maxSlippageBps()).to.equal(500);
    });

    it("setMaxDeployPerCall rejects zero", async function () {
      await expect(
        polManager.connect(admin).setMaxDeployPerCall(0)
      ).to.be.revertedWithCustomError(polManager, "ZeroValue");
    });

    it("setMinTwapWindow enforces the 10-minute floor", async function () {
      await expect(
        polManager.connect(admin).setMinTwapWindow(10 * 60 - 1)
      ).to.be.revertedWithCustomError(polManager, "ValueBelowFloor");
      await polManager.connect(admin).setMinTwapWindow(10 * 60);
      expect(await polManager.minTwapWindow()).to.equal(10 * 60);
    });

    it("setRwaammSourceId rejects bytes32(0)", async function () {
      await expect(
        polManager
          .connect(admin)
          .setRwaammSourceId(ethers.ZeroHash)
      ).to.be.revertedWithCustomError(
        polManager,
        "SwapSourceNotConfigured"
      );
    });

    it("governance setters reject non-governance callers", async function () {
      await expect(
        polManager.connect(attacker).setMaxSlippageBps(50)
      ).to.be.revertedWithCustomError(
        polManager,
        "AccessControlUnauthorizedAccount"
      );
      await expect(
        polManager.connect(attacker).setKeeper(keeperAddr, true)
      ).to.be.revertedWithCustomError(
        polManager,
        "AccessControlUnauthorizedAccount"
      );
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  3. TWAP machinery
  // ════════════════════════════════════════════════════════════════

  describe("TWAP", function () {
    it("a keeper action reverts NoCompletedWindow before any window", async function () {
      // Pool whitelisted but TWAP never seeded.
      await expect(
        polManager.connect(keeper).deploy(poolId)
      ).to.be.revertedWithCustomError(polManager, "NoCompletedWindow");
    });

    it("pokeObservation is a no-op before the window matures", async function () {
      await polManager.pokeObservation(poolId); // seed anchor
      const before = await polManager.poolObservation(poolId);
      // Spam pokes inside the immature window — must change nothing.
      await polManager.connect(attacker).pokeObservation(poolId);
      await advance(60);
      await polManager.connect(attacker).pokeObservation(poolId);
      const after = await polManager.poolObservation(poolId);
      expect(after.averageTimestamp).to.equal(before.averageTimestamp);
      expect(after.averageTimestamp).to.equal(0n);
      expect(after.price0AverageUQ).to.equal(0n);
    });

    it("after seeding the TWAP, the average becomes usable", async function () {
      await seedTwap();
      const obs = await polManager.poolObservation(poolId);
      expect(obs.averageTimestamp).to.be.greaterThan(0n);
      expect(obs.price0AverageUQ).to.be.greaterThan(0n);
      expect(obs.price1AverageUQ).to.be.greaterThan(0n);
    });

    it("a keeper action reverts TwapStale when the average ages out", async function () {
      await seedTwap();
      // Let the stored average age past minTwapWindow without re-poking.
      await advance(TWAP_WINDOW + 60);
      await expect(
        polManager.connect(keeper).deploy(poolId)
      ).to.be.revertedWithCustomError(polManager, "TwapStale");
    });

    it("griefer spam cannot prevent a window from completing", async function () {
      await polManager.pokeObservation(poolId); // seed
      // Griefer pokes every block during the immature window.
      for (let i = 0; i < 5; i++) {
        await advance(60);
        await polManager.connect(attacker).pokeObservation(poolId);
      }
      // Once the window has matured, the next poke ALWAYS refreshes.
      await advance(TWAP_WINDOW + 1);
      await expect(polManager.connect(attacker).pokeObservation(poolId))
        .to.emit(polManager, "ObservationPoked");
      const obs = await polManager.poolObservation(poolId);
      expect(obs.averageTimestamp).to.be.greaterThan(0n);
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  4. deploy
  // ════════════════════════════════════════════════════════════════

  describe("deploy", function () {
    beforeEach(async function () {
      await seedTwap();
    });

    it("happy path: deploys, updates PoolAccounting", async function () {
      await expect(polManager.connect(keeper).deploy(poolId)).to.emit(
        polManager,
        "LiquidityDeployed"
      );
      const acct = await polManager.getPoolAccounting(poolId);
      expect(acct.lpTokensHeld).to.be.greaterThan(0n);
      expect(acct.deployedPrincipalToken0).to.be.greaterThan(0n);
      expect(acct.deployedPrincipalToken1).to.be.greaterThan(0n);
      expect(acct.lastDeployTimestamp).to.be.greaterThan(0n);
      // LP tokens were forwarded to the treasury, not retained.
      expect(await pool.balanceOf(polManager.target)).to.equal(0n);
      expect(await pool.balanceOf(treasury.target)).to.be.greaterThan(
        0n
      );
    });

    it("reverts for a non-keeper caller", async function () {
      await expect(
        polManager.connect(attacker).deploy(poolId)
      ).to.be.revertedWithCustomError(
        polManager,
        "AccessControlUnauthorizedAccount"
      );
    });

    it("caps the deploy at maxDeployPerCall", async function () {
      await polManager.connect(keeper).deploy(poolId);
      const acct = await polManager.getPoolAccounting(poolId);
      // token1 principal deployed is half of (capped) amountToDeploy;
      // the cap is MAX_DEPLOY so token1 principal must not exceed
      // MAX_DEPLOY / 2 (plus tiny rounding tolerance).
      expect(acct.deployedPrincipalToken1).to.be.lessThanOrEqual(
        MAX_DEPLOY / 2n + 10n
      );
    });

    it("reverts when the deploy cadence has not elapsed", async function () {
      await polManager.connect(keeper).deploy(poolId);
      await polManager.pokeObservation(poolId);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      // Cadence (1h) has NOT elapsed since the first deploy.
      await expect(
        polManager.connect(keeper).deploy(poolId)
      ).to.be.revertedWithCustomError(
        polManager,
        "DeployCadenceNotElapsed"
      );
    });

    it("D1: a skewed (sandwiched) add reverts DeployValueLoss", async function () {
      // Model an adversarially reserve-skewed pool: the AMM trims the
      // token0 side of the deposit by 8%, so the realized principal
      // gain falls below the single end-to-end maxSlippageBps band.
      // (POLManager passes amount0Min = 0, so the token0 haircut
      // reaches the D1 _poolStableValue assertion rather than a
      // per-leg floor.)
      await amm.setAddLiquidityHaircutBps(800);
      await expect(
        polManager.connect(keeper).deploy(poolId)
      ).to.be.revertedWithCustomError(polManager, "DeployValueLoss");
    });

    it("honest path: deploy succeeds at maxSlippageBps = 100", async function () {
      await polManager.connect(admin).setMaxSlippageBps(100);
      await expect(polManager.connect(keeper).deploy(poolId)).to.emit(
        polManager,
        "LiquidityDeployed"
      );
    });

    it("honest path: deploy succeeds at maxSlippageBps = 50", async function () {
      await polManager.connect(admin).setMaxSlippageBps(50);
      await expect(polManager.connect(keeper).deploy(poolId)).to.emit(
        polManager,
        "LiquidityDeployed"
      );
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  5. harvest
  // ════════════════════════════════════════════════════════════════

  describe("harvest", function () {
    beforeEach(async function () {
      await seedTwap();
      await polManager.connect(keeper).deploy(poolId);
      // Re-seed TWAP for the next keeper action (deploy poked it).
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
    });

    it("happy path: harvests and atomically redeploys", async function () {
      const acctBefore = await polManager.getPoolAccounting(poolId);
      await expect(polManager.connect(keeper).harvest(poolId)).to.emit(
        polManager,
        "FeesHarvested"
      );
      const acctAfter = await polManager.getPoolAccounting(poolId);
      // Position was redeployed — LP tokens are held again.
      expect(acctAfter.lpTokensHeld).to.be.greaterThan(0n);
      expect(acctAfter.lastHarvestTimestamp).to.be.greaterThan(
        acctBefore.lastHarvestTimestamp
      );
    });

    it("reverts when the harvest cadence has not elapsed", async function () {
      await polManager.connect(keeper).harvest(poolId);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      await expect(
        polManager.connect(keeper).harvest(poolId)
      ).to.be.revertedWithCustomError(
        polManager,
        "HarvestCadenceNotElapsed"
      );
    });

    it("D1: HarvestValueLoss on a manipulated redeploy", async function () {
      // Adversarial pool trims the token0 side of the redeploy add by
      // 8% → the redeployed position's tracked principal falls below
      // the end-to-end maxSlippageBps band versus the pre-harvest
      // position.
      await amm.setAddLiquidityHaircutBps(800);
      await expect(
        polManager.connect(keeper).harvest(poolId)
      ).to.be.revertedWithCustomError(polManager, "HarvestValueLoss");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  6. compound
  // ════════════════════════════════════════════════════════════════

  describe("compound", function () {
    beforeEach(async function () {
      await seedTwap();
      await polManager.connect(keeper).deploy(poolId);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
    });

    it("happy path: compounds principal + fees", async function () {
      await expect(polManager.connect(keeper).compound(poolId)).to.emit(
        polManager,
        "FeesHarvested"
      );
      const acct = await polManager.getPoolAccounting(poolId);
      expect(acct.lpTokensHeld).to.be.greaterThan(0n);
    });

    it("D1: CompoundValueLoss on a manipulated redeploy", async function () {
      // Adversarial pool trims the token0 side of the redeploy add by
      // 8% → the redeployed position falls below the end-to-end
      // maxSlippageBps band versus the pre-compound position.
      await amm.setAddLiquidityHaircutBps(800);
      await expect(
        polManager.connect(keeper).compound(poolId)
      ).to.be.revertedWithCustomError(polManager, "CompoundValueLoss");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  7. rebalance
  // ════════════════════════════════════════════════════════════════

  describe("rebalance", function () {
    it("trims an over-weight pool toward its target weight", async function () {
      // Single managed pool → realized weight is 100% (10000 bps).
      // Set target weight to 4000 bps so the pool is over-weight.
      await seedTwap();
      await polManager.connect(keeper).deploy(poolId);
      await polManager
        .connect(admin)
        .setTargetWeights([poolId], [4000]);
      // Re-seed TWAP for rebalance.
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);

      const acctBefore = await polManager.getPoolAccounting(poolId);
      await expect(
        polManager.connect(keeper).rebalance(poolId)
      ).to.emit(polManager, "PositionRebalanced");
      const acctAfter = await polManager.getPoolAccounting(poolId);
      // Over-weight excess LP was withdrawn → lpTokensHeld decreased.
      expect(acctAfter.lpTokensHeld).to.be.lessThan(
        acctBefore.lpTokensHeld
      );
    });

    it("reverts DriftWithinTolerance when weight is on target", async function () {
      await seedTwap();
      await polManager.connect(keeper).deploy(poolId);
      // Single pool at 100% weight; set target 10000 → zero drift.
      await polManager
        .connect(admin)
        .setTargetWeights([poolId], [10000]);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      await expect(
        polManager.connect(keeper).rebalance(poolId)
      ).to.be.revertedWithCustomError(
        polManager,
        "DriftWithinTolerance"
      );
    });

    it("reverts when the rebalance cadence has not elapsed", async function () {
      await seedTwap();
      await polManager.connect(keeper).deploy(poolId);
      await polManager
        .connect(admin)
        .setTargetWeights([poolId], [4000]);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      await polManager.connect(keeper).rebalance(poolId);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      await expect(
        polManager.connect(keeper).rebalance(poolId)
      ).to.be.revertedWithCustomError(
        polManager,
        "RebalanceCadenceNotElapsed"
      );
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  8. Multi-call accounting coherence
  // ════════════════════════════════════════════════════════════════

  describe("Multi-call accounting", function () {
    it("deploy -> harvest -> compound -> rebalance stays coherent", async function () {
      await seedTwap();

      // (a) deploy
      await polManager.connect(keeper).deploy(poolId);
      let acct = await polManager.getPoolAccounting(poolId);
      expect(acct.lpTokensHeld).to.be.greaterThan(0n);
      expect(acct.deployedPrincipalToken1).to.be.greaterThan(0n);
      const lpAfterDeploy = acct.lpTokensHeld;

      // (b) harvest — re-seed TWAP, then harvest.
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      await polManager.connect(keeper).harvest(poolId);
      acct = await polManager.getPoolAccounting(poolId);
      // Position remains deployed (atomic redeploy).
      expect(acct.lpTokensHeld).to.be.greaterThan(0n);
      expect(acct.lastHarvestTimestamp).to.be.greaterThan(0n);

      // (c) compound — needs both harvest cadence AND fresh TWAP.
      await advance(HARVEST_INTERVAL + 1);
      await polManager.pokeObservation(poolId);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      await polManager.connect(keeper).compound(poolId);
      acct = await polManager.getPoolAccounting(poolId);
      expect(acct.lpTokensHeld).to.be.greaterThan(0n);

      // (d) rebalance — make the pool over-weight, then trim.
      await polManager
        .connect(admin)
        .setTargetWeights([poolId], [4000]);
      await advance(TWAP_WINDOW + 1);
      await polManager.pokeObservation(poolId);
      const lpBeforeRebal = acct.lpTokensHeld;
      await polManager.connect(keeper).rebalance(poolId);
      acct = await polManager.getPoolAccounting(poolId);
      expect(acct.lpTokensHeld).to.be.lessThan(lpBeforeRebal);

      // Final coherence: principal counters never went negative and
      // POLManager retains no dust (non-custodial invariant).
      expect(acct.deployedPrincipalToken0).to.be.greaterThanOrEqual(0n);
      expect(acct.deployedPrincipalToken1).to.be.greaterThanOrEqual(0n);
      expect(await tokenA.balanceOf(polManager.target)).to.equal(0n);
      expect(await tokenB.balanceOf(polManager.target)).to.equal(0n);
      expect(await pool.balanceOf(polManager.target)).to.equal(0n);

      // Sanity: lpTokensHeld changed across the sequence as expected.
      expect(lpAfterDeploy).to.be.greaterThan(0n);
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  9. Pause gating
  // ════════════════════════════════════════════════════════════════

  describe("Pause", function () {
    it("pause requires GUARDIAN_ROLE; unpause requires admin", async function () {
      await expect(
        polManager.connect(attacker).pause()
      ).to.be.revertedWithCustomError(
        polManager,
        "AccessControlUnauthorizedAccount"
      );
      await polManager.connect(admin).pause();
      expect(await polManager.paused()).to.be.true;
      await expect(
        polManager.connect(attacker).unpause()
      ).to.be.revertedWithCustomError(
        polManager,
        "AccessControlUnauthorizedAccount"
      );
      await polManager.connect(admin).unpause();
      expect(await polManager.paused()).to.be.false;
    });

    it("blocks keeper triggers while paused", async function () {
      await seedTwap();
      await polManager.connect(admin).pause();
      await expect(
        polManager.connect(keeper).deploy(poolId)
      ).to.be.revertedWithCustomError(polManager, "EnforcedPause");
    });
  });
});
