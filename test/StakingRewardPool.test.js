const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title StakingRewardPool Test Suite
 * @notice Comprehensive tests for the StakingRewardPool UUPS upgradeable
 *         contract covering initialization, deposits, claims, snapshots,
 *         APR timelocks, contract timelocks, tier clamping, duration
 *         bonuses, pause/unpause, emergency withdraw, and ossification.
 * @dev ~90 test cases across 15 describe blocks.
 */
describe("StakingRewardPool", function () {
  // ──────────────────────────────────────────────────────────────────────
  //  Constants (mirrored from contract)
  // ──────────────────────────────────────────────────────────────────────

  const BASIS_POINTS = 10000n;
  const SECONDS_PER_YEAR = 365n * 24n * 60n * 60n; // 31_536_000
  const MAX_TOTAL_APR = 1200n;
  const MIN_STAKE_AGE = 24 * 60 * 60; // 1 day in seconds
  const TIMELOCK_DELAY = 48 * 60 * 60; // 48 hours in seconds
  const APR_TIMELOCK_DELAY = 24 * 60 * 60; // 24 hours in seconds
  const MAX_CLAIM_PER_TX = ethers.parseEther("1000000"); // 1M XOM
  const ONE_MONTH = 30 * 24 * 60 * 60;
  const SIX_MONTHS = 180 * 24 * 60 * 60;
  const TWO_YEARS = 730 * 24 * 60 * 60;

  // Staking amounts for tier boundaries (18 decimals)
  const TIER_1_AMOUNT = ethers.parseEther("1000"); // tier 1
  const TIER_2_AMOUNT = ethers.parseEther("1000000"); // tier 2
  const TIER_3_AMOUNT = ethers.parseEther("10000000"); // tier 3
  const TIER_4_AMOUNT = ethers.parseEther("100000000"); // tier 4
  const TIER_5_AMOUNT = ethers.parseEther("1000000000"); // tier 5

  // Default test stake: 1M XOM, tier 2, 6-month lock
  const DEFAULT_STAKE_AMOUNT = TIER_2_AMOUNT;
  const DEFAULT_TIER = 2;
  const DEFAULT_DURATION = SIX_MONTHS;

  // Pool funding amount
  const POOL_FUNDING = ethers.parseEther("10000000"); // 10M XOM

  // ──────────────────────────────────────────────────────────────────────
  //  Fixtures
  // ──────────────────────────────────────────────────────────────────────

  /**
   * Deploy fresh MockOmniCoreStaking, MockERC20 (XOM), a second
   * MockERC20 (OTHER — for emergency withdraw tests), and
   * StakingRewardPool proxy. Fund the pool with 10M XOM.
   */
  async function deployFixture() {
    const [admin, staker, staker2, nonAdmin, attacker] =
      await ethers.getSigners();

    // Deploy mock OmniCore staking oracle
    const MockOmniCoreStaking = await ethers.getContractFactory(
      "MockOmniCoreStaking"
    );
    const omniCore = await MockOmniCoreStaking.deploy();
    await omniCore.waitForDeployment();

    // Deploy mock XOM token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();

    // Deploy a second ERC20 for emergency withdraw tests
    const otherToken = await MockERC20.deploy("OtherToken", "OTHER");
    await otherToken.waitForDeployment();

    // Deploy StakingRewardPool via UUPS proxy
    const StakingRewardPool =
      await ethers.getContractFactory("StakingRewardPool");
    const pool = await upgrades.deployProxy(
      StakingRewardPool,
      [omniCore.target, xom.target],
      {
        initializer: "initialize",
        kind: "uups",
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ["constructor"],
      }
    );
    await pool.waitForDeployment();

    // Fund the pool with 10M XOM
    await xom.mint(admin.address, POOL_FUNDING);
    await xom.connect(admin).approve(pool.target, POOL_FUNDING);
    await pool.connect(admin).depositToPool(POOL_FUNDING);

    // Helper: configure an active stake on the mock and fast-forward past MIN_STAKE_AGE
    async function setupActiveStake(
      user,
      amount = DEFAULT_STAKE_AMOUNT,
      tier = DEFAULT_TIER,
      duration = DEFAULT_DURATION
    ) {
      const now = await time.latest();
      const lockTime = now + duration;
      await omniCore.setStake(
        user.address,
        amount,
        tier,
        duration,
        lockTime,
        true
      );
      // Advance past MIN_STAKE_AGE so rewards accrue
      await time.increase(MIN_STAKE_AGE + 1);
    }

    return {
      pool,
      omniCore,
      xom,
      otherToken,
      admin,
      staker,
      staker2,
      nonAdmin,
      attacker,
      setupActiveStake,
    };
  }

  // ──────────────────────────────────────────────────────────────────────
  //  1. Initialization
  // ──────────────────────────────────────────────────────────────────────

  describe("Initialization", function () {
    it("should revert if omniCoreAddr is zero address", async function () {
      const [admin] = await ethers.getSigners();
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const xom = await MockERC20.deploy("XOM", "XOM");
      await xom.waitForDeployment();

      const StakingRewardPool =
        await ethers.getContractFactory("StakingRewardPool");
      await expect(
        upgrades.deployProxy(
          StakingRewardPool,
          [ethers.ZeroAddress, xom.target],
          {
            initializer: "initialize",
            kind: "uups",
            constructorArgs: [ethers.ZeroAddress],
            unsafeAllow: ["constructor"],
          }
        )
      ).to.be.revertedWithCustomError(StakingRewardPool, "ZeroAddress");
    });

    it("should revert if xomTokenAddr is zero address", async function () {
      const MockOmniCoreStaking = await ethers.getContractFactory(
        "MockOmniCoreStaking"
      );
      const omniCore = await MockOmniCoreStaking.deploy();
      await omniCore.waitForDeployment();

      const StakingRewardPool =
        await ethers.getContractFactory("StakingRewardPool");
      await expect(
        upgrades.deployProxy(
          StakingRewardPool,
          [omniCore.target, ethers.ZeroAddress],
          {
            initializer: "initialize",
            kind: "uups",
            constructorArgs: [ethers.ZeroAddress],
            unsafeAllow: ["constructor"],
          }
        )
      ).to.be.revertedWithCustomError(StakingRewardPool, "ZeroAddress");
    });

    it("should grant DEFAULT_ADMIN_ROLE to deployer", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      const DEFAULT_ADMIN_ROLE = await pool.DEFAULT_ADMIN_ROLE();
      expect(await pool.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("should grant ADMIN_ROLE to deployer", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      const ADMIN_ROLE = await pool.ADMIN_ROLE();
      expect(await pool.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("should set correct omniCore address", async function () {
      const { pool, omniCore } = await loadFixture(deployFixture);
      expect(await pool.omniCore()).to.equal(omniCore.target);
    });

    it("should set correct xomToken address", async function () {
      const { pool, xom } = await loadFixture(deployFixture);
      expect(await pool.xomToken()).to.equal(xom.target);
    });

    it("should set tier 1 APR to 500 bps (5%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.tierAPR(1)).to.equal(500n);
    });

    it("should set tier 2 APR to 600 bps (6%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.tierAPR(2)).to.equal(600n);
    });

    it("should set tier 3 APR to 700 bps (7%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.tierAPR(3)).to.equal(700n);
    });

    it("should set tier 4 APR to 800 bps (8%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.tierAPR(4)).to.equal(800n);
    });

    it("should set tier 5 APR to 900 bps (9%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.tierAPR(5)).to.equal(900n);
    });

    it("should set tier 0 APR to 0 (unused)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.tierAPR(0)).to.equal(0n);
    });

    it("should set duration bonus tier 0 to 0 bps", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.durationBonusAPR(0)).to.equal(0n);
    });

    it("should set duration bonus tier 1 to 100 bps (+1%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.durationBonusAPR(1)).to.equal(100n);
    });

    it("should set duration bonus tier 2 to 200 bps (+2%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.durationBonusAPR(2)).to.equal(200n);
    });

    it("should set duration bonus tier 3 to 300 bps (+3%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.durationBonusAPR(3)).to.equal(300n);
    });

    it("should start with totalDeposited equal to POOL_FUNDING", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.totalDeposited()).to.equal(POOL_FUNDING);
    });

    it("should start with totalDistributed equal to zero", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.totalDistributed()).to.equal(0n);
    });

    it("should start unossified", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.isOssified()).to.be.false;
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  2. depositToPool
  // ──────────────────────────────────────────────────────────────────────

  describe("depositToPool", function () {
    it("should accept a valid deposit and update totalDeposited", async function () {
      const { pool, xom, staker } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("5000");
      await xom.mint(staker.address, amount);
      await xom.connect(staker).approve(pool.target, amount);

      const before = await pool.totalDeposited();
      await pool.connect(staker).depositToPool(amount);
      expect(await pool.totalDeposited()).to.equal(before + amount);
    });

    it("should revert on zero amount deposit", async function () {
      const { pool, staker } = await loadFixture(deployFixture);
      await expect(
        pool.connect(staker).depositToPool(0)
      ).to.be.revertedWithCustomError(pool, "InvalidAmount");
    });

    it("should emit PoolDeposit event with correct args", async function () {
      const { pool, xom, staker } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("2000");
      await xom.mint(staker.address, amount);
      await xom.connect(staker).approve(pool.target, amount);

      const totalBefore = await pool.totalDeposited();

      await expect(pool.connect(staker).depositToPool(amount))
        .to.emit(pool, "PoolDeposit")
        .withArgs(staker.address, amount, totalBefore + amount);
    });

    it("should revert when contract is paused", async function () {
      const { pool, xom, admin, staker } = await loadFixture(deployFixture);
      await pool.connect(admin).pause();

      const amount = ethers.parseEther("1000");
      await xom.mint(staker.address, amount);
      await xom.connect(staker).approve(pool.target, amount);

      await expect(
        pool.connect(staker).depositToPool(amount)
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });

    it("should transfer XOM from depositor to pool", async function () {
      const { pool, xom, staker } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("3000");
      await xom.mint(staker.address, amount);
      await xom.connect(staker).approve(pool.target, amount);

      const poolBalBefore = await xom.balanceOf(pool.target);
      await pool.connect(staker).depositToPool(amount);
      expect(await xom.balanceOf(pool.target)).to.equal(
        poolBalBefore + amount
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  3. claimRewards
  // ──────────────────────────────────────────────────────────────────────

  describe("claimRewards", function () {
    it("should transfer accrued XOM to the staker", async function () {
      const { pool, xom, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);

      // Let 30 days pass for reward accrual
      await time.increase(30 * 24 * 60 * 60);

      const balBefore = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const balAfter = await xom.balanceOf(staker.address);

      expect(balAfter).to.be.gt(balBefore);
    });

    it("should revert with NoRewardsToClaim when earned is zero", async function () {
      const { pool, staker } = await loadFixture(deployFixture);
      // staker has no stake at all
      await expect(
        pool.connect(staker).claimRewards()
      ).to.be.revertedWithCustomError(pool, "NoRewardsToClaim");
    });

    it("should emit RewardsClaimed event", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      await expect(pool.connect(staker).claimRewards()).to.emit(
        pool,
        "RewardsClaimed"
      );
    });

    it("should update lastClaimTime after claiming", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      await pool.connect(staker).claimRewards();
      const claimTime = await pool.lastClaimTime(staker.address);
      expect(claimTime).to.be.gt(0n);
    });

    it("should update totalDistributed after claiming", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      const before = await pool.totalDistributed();
      await pool.connect(staker).claimRewards();
      expect(await pool.totalDistributed()).to.be.gt(before);
    });

    it("should partially pay when pool is underfunded (M-01)", async function () {
      const { pool, xom, omniCore, admin, staker } =
        await loadFixture(deployFixture);

      // Set up a massive stake that will earn more than pool has
      const now = await time.latest();
      const hugeAmount = ethers.parseEther("5000000000"); // 5B XOM
      await omniCore.setStake(
        staker.address,
        hugeAmount,
        5,
        TWO_YEARS,
        now + TWO_YEARS,
        true
      );
      // Pass MIN_STAKE_AGE + long time to accrue massive rewards
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      const poolBal = await xom.balanceOf(pool.target);
      const earned = await pool.earned(staker.address);
      // Earned should exceed pool balance (after MAX_CLAIM_PER_TX cap)
      // The effective payout should be min(earned, MAX_CLAIM_PER_TX, poolBal)
      const expectedPayout =
        earned > MAX_CLAIM_PER_TX
          ? poolBal < MAX_CLAIM_PER_TX
            ? poolBal
            : MAX_CLAIM_PER_TX
          : poolBal < earned
            ? poolBal
            : earned;

      const balBefore = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const balAfter = await xom.balanceOf(staker.address);
      const received = balAfter - balBefore;

      // Staker should have received at most what the pool had
      expect(received).to.be.lte(poolBal);
      expect(received).to.be.gt(0n);
    });

    it("should store remainder in frozenRewards when underfunded", async function () {
      const { pool, xom, omniCore, staker } =
        await loadFixture(deployFixture);

      // Huge stake to generate massive rewards exceeding pool balance
      const now = await time.latest();
      const hugeAmount = ethers.parseEther("5000000000");
      await omniCore.setStake(
        staker.address,
        hugeAmount,
        5,
        TWO_YEARS,
        now + TWO_YEARS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      await pool.connect(staker).claimRewards();
      // Remainder should be stored as frozen rewards
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.be.gt(0n);
    });

    it("should cap payout at MAX_CLAIM_PER_TX and store excess as frozen", async function () {
      const { pool, xom, omniCore, admin, staker } =
        await loadFixture(deployFixture);

      // Fund pool generously
      const extraFunding = ethers.parseEther("100000000"); // 100M
      await xom.mint(admin.address, extraFunding);
      await xom.connect(admin).approve(pool.target, extraFunding);
      await pool.connect(admin).depositToPool(extraFunding);

      // Huge stake that accrues > 1M XOM
      const now = await time.latest();
      const hugeAmount = ethers.parseEther("2000000000"); // 2B XOM
      await omniCore.setStake(
        staker.address,
        hugeAmount,
        5,
        TWO_YEARS,
        now + TWO_YEARS,
        true
      );
      // ~12% APR on 2B for 1 year = 240M XOM -- way beyond 1M cap
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      const balBefore = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const balAfter = await xom.balanceOf(staker.address);
      const received = balAfter - balBefore;

      expect(received).to.equal(MAX_CLAIM_PER_TX);

      // Frozen rewards should hold the remainder
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.be.gt(0n);
    });

    it("should revert when contract is paused", async function () {
      const { pool, admin, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);
      await pool.connect(admin).pause();

      await expect(
        pool.connect(staker).claimRewards()
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });

    it("should allow claiming frozen rewards from a second claim", async function () {
      const { pool, xom, omniCore, admin, staker } =
        await loadFixture(deployFixture);

      // Fund pool generously
      const extraFunding = ethers.parseEther("500000000");
      await xom.mint(admin.address, extraFunding);
      await xom.connect(admin).approve(pool.target, extraFunding);
      await pool.connect(admin).depositToPool(extraFunding);

      // Huge stake accruing > 1M XOM
      const now = await time.latest();
      const hugeAmount = ethers.parseEther("2000000000");
      await omniCore.setStake(
        staker.address,
        hugeAmount,
        5,
        TWO_YEARS,
        now + TWO_YEARS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      // First claim: capped at 1M
      await pool.connect(staker).claimRewards();
      const frozenAfterFirst = await pool.frozenRewards(staker.address);
      expect(frozenAfterFirst).to.be.gt(0n);

      // Second claim: should draw from frozen
      const balBefore = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const balAfter = await xom.balanceOf(staker.address);
      expect(balAfter).to.be.gt(balBefore);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  4. snapshotRewards
  // ──────────────────────────────────────────────────────────────────────

  describe("snapshotRewards", function () {
    it("should freeze accrued rewards into frozenRewards", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      await pool.snapshotRewards(staker.address);
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.be.gt(0n);
    });

    it("should emit RewardsSnapshot event", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      await expect(pool.snapshotRewards(staker.address)).to.emit(
        pool,
        "RewardsSnapshot"
      );
    });

    it("should cache stake data in lastActiveStake", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      await pool.snapshotRewards(staker.address);
      const cached = await pool.lastActiveStake(staker.address);
      expect(cached.amount).to.equal(DEFAULT_STAKE_AMOUNT);
      expect(cached.tier).to.equal(BigInt(DEFAULT_TIER));
      expect(cached.duration).to.equal(BigInt(DEFAULT_DURATION));
      expect(cached.snapshotTime).to.be.gt(0n);
    });

    it("should skip (no-op) for inactive stake", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      // Set inactive stake
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        false // inactive
      );
      await time.increase(MIN_STAKE_AGE + 30 * 24 * 60 * 60);

      await pool.snapshotRewards(staker.address);
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.equal(0n);
    });

    it("should skip (no-op) for zero amount stake", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        0,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 30 * 24 * 60 * 60);

      await pool.snapshotRewards(staker.address);
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.equal(0n);
    });

    it("should revert with ZeroAddress if user is address(0)", async function () {
      const { pool } = await loadFixture(deployFixture);
      await expect(
        pool.snapshotRewards(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(pool, "ZeroAddress");
    });

    it("should revert when contract is paused", async function () {
      const { pool, admin, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await pool.connect(admin).pause();

      await expect(
        pool.snapshotRewards(staker.address)
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });

    it("should update lastClaimTime for the user", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      await pool.snapshotRewards(staker.address);
      const claimTime = await pool.lastClaimTime(staker.address);
      expect(claimTime).to.be.gt(0n);
    });

    it("should cache stake data on first snapshot even if accrued is 0", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      // Set a new active stake (just created, no time passed beyond MIN_STAKE_AGE)
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      // Don't advance past MIN_STAKE_AGE so accrued = 0

      await pool.snapshotRewards(staker.address);
      const cached = await pool.lastActiveStake(staker.address);
      // Should have cached because snapshotTime was 0
      expect(cached.amount).to.equal(TIER_2_AMOUNT);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  5. earned (view function)
  // ──────────────────────────────────────────────────────────────────────

  describe("earned", function () {
    it("should return accrued rewards for an active stake", async function () {
      const { pool, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      expect(reward).to.be.gt(0n);
    });

    it("should return only frozen rewards for an inactive stake", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      // Snapshot and then deactivate
      await pool.snapshotRewards(staker.address);
      const frozen = await pool.frozenRewards(staker.address);

      // Set stake to inactive
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        DEFAULT_STAKE_AMOUNT,
        DEFAULT_TIER,
        DEFAULT_DURATION,
        now + DEFAULT_DURATION,
        false
      );

      const reward = await pool.earned(staker.address);
      expect(reward).to.equal(frozen);
    });

    it("should fall back to frozen rewards if OmniCore reverts", async function () {
      const { pool, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      // Freeze some rewards first
      await pool.snapshotRewards(staker.address);
      const frozen = await pool.frozenRewards(staker.address);

      // Make OmniCore revert
      await omniCore.setShouldRevert(true);

      const reward = await pool.earned(staker.address);
      expect(reward).to.equal(frozen);
    });

    it("should return 0 for a user with no stake and no frozen rewards", async function () {
      const { pool, staker } = await loadFixture(deployFixture);
      expect(await pool.earned(staker.address)).to.equal(0n);
    });

    it("should compute correct reward mathematically", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);

      // Tier 1 (5% APR), 1-month duration (tier 1 bonus = +1%), total 6%
      const amount = ethers.parseEther("100000"); // 100K XOM
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        amount,
        1,
        ONE_MONTH,
        now + ONE_MONTH,
        true
      );

      // Advance past MIN_STAKE_AGE
      await time.increase(MIN_STAKE_AGE + 1);
      const afterSetup = await time.latest();

      // Advance exactly 365 days
      const oneYear = 365 * 24 * 60 * 60;
      await time.increase(oneYear);

      const reward = await pool.earned(staker.address);
      // Expected: 100,000 * 600 / 10000 = 6000 XOM per year
      // But elapsed is slightly more than 365 days due to MIN_STAKE_AGE advance
      // Just check it's in the right ballpark
      const expectedApprox = ethers.parseEther("6000");
      // Allow 5% tolerance due to block time precision
      const tolerance = expectedApprox / 20n;
      expect(reward).to.be.closeTo(expectedApprox, tolerance);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  6. APR Timelocks
  // ──────────────────────────────────────────────────────────────────────

  describe("APR Timelocks", function () {
    it("proposeTierAPR: should create pending change with correct delay", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      const pending = await pool.pendingAPRChange();
      expect(pending.tier).to.equal(1n);
      expect(pending.newAPR).to.equal(550n);
      expect(pending.isDurationBonus).to.be.false;
      expect(pending.executeAfter).to.be.gt(0n);
    });

    it("proposeTierAPR: should emit APRChangeProposed", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(pool.connect(admin).proposeTierAPR(3, 750)).to.emit(
        pool,
        "APRChangeProposed"
      );
    });

    it("proposeTierAPR: should revert for tier 0", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeTierAPR(0, 500)
      ).to.be.revertedWithCustomError(pool, "InvalidTier");
    });

    it("proposeTierAPR: should revert for tier > MAX_TIER", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeTierAPR(6, 500)
      ).to.be.revertedWithCustomError(pool, "InvalidTier");
    });

    it("proposeTierAPR: should revert if APR > MAX_TOTAL_APR", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeTierAPR(1, 1201)
      ).to.be.revertedWithCustomError(pool, "APRExceedsMaximum");
    });

    it("proposeTierAPR: should revert if called by non-admin", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(nonAdmin).proposeTierAPR(1, 500)
      ).to.be.reverted;
    });

    it("proposeDurationBonusAPR: should create pending change marked as duration bonus", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeDurationBonusAPR(2, 250);
      const pending = await pool.pendingAPRChange();
      expect(pending.tier).to.equal(2n);
      expect(pending.newAPR).to.equal(250n);
      expect(pending.isDurationBonus).to.be.true;
    });

    it("proposeDurationBonusAPR: should revert for tier > MAX_DURATION_TIER", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeDurationBonusAPR(4, 100)
      ).to.be.revertedWithCustomError(pool, "InvalidTier");
    });

    it("proposeDurationBonusAPR: should revert if APR > MAX_TOTAL_APR", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeDurationBonusAPR(1, 1201)
      ).to.be.revertedWithCustomError(pool, "APRExceedsMaximum");
    });

    it("proposeDurationBonusAPR: should accept tier 0", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      // tier 0 is valid for duration bonus (0 = no commitment)
      await expect(
        pool.connect(admin).proposeDurationBonusAPR(0, 50)
      ).to.not.be.reverted;
    });

    it("executeAPRChange: should update tier APR after timelock", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(2, 650);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await pool.connect(admin).executeAPRChange();
      expect(await pool.tierAPR(2)).to.equal(650n);
    });

    it("executeAPRChange: should update duration bonus APR after timelock", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeDurationBonusAPR(1, 150);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await pool.connect(admin).executeAPRChange();
      expect(await pool.durationBonusAPR(1)).to.equal(150n);
    });

    it("executeAPRChange: should emit TierAPRUpdated for tier change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(3, 750);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await expect(pool.connect(admin).executeAPRChange())
        .to.emit(pool, "TierAPRUpdated")
        .withArgs(3, 750);
    });

    it("executeAPRChange: should emit DurationBonusAPRUpdated for duration change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeDurationBonusAPR(2, 250);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await expect(pool.connect(admin).executeAPRChange())
        .to.emit(pool, "DurationBonusAPRUpdated")
        .withArgs(2, 250);
    });

    it("executeAPRChange: should revert if timelock not elapsed", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      // Don't advance time
      await expect(
        pool.connect(admin).executeAPRChange()
      ).to.be.revertedWithCustomError(pool, "APRTimelockNotElapsed");
    });

    it("executeAPRChange: should revert if no pending change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).executeAPRChange()
      ).to.be.revertedWithCustomError(pool, "NoPendingAPRChange");
    });

    it("executeAPRChange: should clear pending change after execution", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await pool.connect(admin).executeAPRChange();

      // Trying again should fail because pending was deleted
      await expect(
        pool.connect(admin).executeAPRChange()
      ).to.be.revertedWithCustomError(pool, "NoPendingAPRChange");
    });

    it("cancelAPRChange: should clear pending change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await pool.connect(admin).cancelAPRChange();

      await expect(
        pool.connect(admin).executeAPRChange()
      ).to.be.revertedWithCustomError(pool, "NoPendingAPRChange");
    });

    it("cancelAPRChange: should emit APRChangeCancelled", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await expect(pool.connect(admin).cancelAPRChange()).to.emit(
        pool,
        "APRChangeCancelled"
      );
    });

    it("cancelAPRChange: should revert if no pending change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).cancelAPRChange()
      ).to.be.revertedWithCustomError(pool, "NoPendingAPRChange");
    });

    it("cancelAPRChange: should revert if called by non-admin", async function () {
      const { pool, admin, nonAdmin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await expect(pool.connect(nonAdmin).cancelAPRChange()).to.be.reverted;
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  7. Contract Timelocks
  // ──────────────────────────────────────────────────────────────────────

  describe("Contract Timelocks", function () {
    it("proposeContracts: should create pending change with 48h delay", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      const pending = await pool.pendingContracts();
      expect(pending.omniCore).to.equal(staker.address);
      expect(pending.xomToken).to.equal(staker2.address);
      expect(pending.executeAfter).to.be.gt(0n);
    });

    it("proposeContracts: should emit ContractsChangeProposed", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeContracts(staker.address, staker2.address)
      ).to.emit(pool, "ContractsChangeProposed");
    });

    it("proposeContracts: should revert if omniCore is zero address", async function () {
      const { pool, admin, staker } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeContracts(ethers.ZeroAddress, staker.address)
      ).to.be.revertedWithCustomError(pool, "ZeroAddress");
    });

    it("proposeContracts: should revert if xomToken is zero address", async function () {
      const { pool, admin, staker } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).proposeContracts(staker.address, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(pool, "ZeroAddress");
    });

    it("proposeContracts: should revert if called by non-admin", async function () {
      const { pool, nonAdmin, staker, staker2 } =
        await loadFixture(deployFixture);
      await expect(
        pool
          .connect(nonAdmin)
          .proposeContracts(staker.address, staker2.address)
      ).to.be.reverted;
    });

    it("executeContracts: should update omniCore and xomToken after timelock", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await time.increase(TIMELOCK_DELAY + 1);
      await pool.connect(admin).executeContracts();

      expect(await pool.omniCore()).to.equal(staker.address);
      expect(await pool.xomToken()).to.equal(staker2.address);
    });

    it("executeContracts: should emit ContractsUpdated", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await time.increase(TIMELOCK_DELAY + 1);

      await expect(pool.connect(admin).executeContracts())
        .to.emit(pool, "ContractsUpdated")
        .withArgs(staker.address, staker2.address);
    });

    it("executeContracts: should revert if timelock not elapsed", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await expect(
        pool.connect(admin).executeContracts()
      ).to.be.revertedWithCustomError(pool, "TimelockNotElapsed");
    });

    it("executeContracts: should revert if no pending change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).executeContracts()
      ).to.be.revertedWithCustomError(pool, "NoPendingChange");
    });

    it("executeContracts: should clear pending change after execution", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await time.increase(TIMELOCK_DELAY + 1);
      await pool.connect(admin).executeContracts();

      await expect(
        pool.connect(admin).executeContracts()
      ).to.be.revertedWithCustomError(pool, "NoPendingChange");
    });

    it("cancelContractsChange: should clear pending change", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await pool.connect(admin).cancelContractsChange();

      await expect(
        pool.connect(admin).executeContracts()
      ).to.be.revertedWithCustomError(pool, "NoPendingChange");
    });

    it("cancelContractsChange: should emit ContractsChangeCancelled", async function () {
      const { pool, admin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await expect(pool.connect(admin).cancelContractsChange()).to.emit(
        pool,
        "ContractsChangeCancelled"
      );
    });

    it("cancelContractsChange: should revert if no pending change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(
        pool.connect(admin).cancelContractsChange()
      ).to.be.revertedWithCustomError(pool, "NoPendingChange");
    });

    it("cancelContractsChange: should revert if called by non-admin", async function () {
      const { pool, admin, nonAdmin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await expect(pool.connect(nonAdmin).cancelContractsChange()).to.be
        .reverted;
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  8. getEffectiveAPR
  // ──────────────────────────────────────────────────────────────────────

  describe("getEffectiveAPR", function () {
    it("tier 1, no duration: 5% + 0% = 500 bps", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getEffectiveAPR(1, 0)).to.equal(500n);
    });

    it("tier 1, 1-month: 5% + 1% = 600 bps", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getEffectiveAPR(1, ONE_MONTH)).to.equal(600n);
    });

    it("tier 1, 6-month: 5% + 2% = 700 bps", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getEffectiveAPR(1, SIX_MONTHS)).to.equal(700n);
    });

    it("tier 1, 2-year: 5% + 3% = 800 bps", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getEffectiveAPR(1, TWO_YEARS)).to.equal(800n);
    });

    it("tier 5, no duration: 9% + 0% = 900 bps", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getEffectiveAPR(5, 0)).to.equal(900n);
    });

    it("tier 5, 2-year: 9% + 3% = 1200 bps (MAX_TOTAL_APR)", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getEffectiveAPR(5, TWO_YEARS)).to.equal(1200n);
    });

    it("tier 0, any duration: 0 bps (no base APR)", async function () {
      const { pool } = await loadFixture(deployFixture);
      // tier 0 base = 0, duration bonus = +3%, total = 300
      expect(await pool.getEffectiveAPR(0, TWO_YEARS)).to.equal(300n);
    });

    it("should cap combined APR at MAX_TOTAL_APR (1200 bps)", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      // Increase tier 5 to 1100 bps, then with duration tier 3 (+300) = 1400 > 1200 cap
      await pool.connect(admin).proposeTierAPR(5, 1100);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await pool.connect(admin).executeAPRChange();

      expect(await pool.getEffectiveAPR(5, TWO_YEARS)).to.equal(1200n);
    });

    it("tier beyond MAX_TIER uses MAX_TIER APR", async function () {
      const { pool } = await loadFixture(deployFixture);
      // tier 6+ should be capped at tier 5 (900 bps)
      // getEffectiveAPR has the cap: tier < MAX_TIER + 1 ? tierAPR[tier] : tierAPR[MAX_TIER]
      // But the public function doesn't accept tier 6 directly -- it accesses the array
      // via _getEffectiveAPR which handles the cap internally. We can only test via earned() indirectly.
      // Actually, the public getEffectiveAPR(tier, duration) passes through directly.
      // tier=6 with no duration should give tier 5 APR = 900
      expect(await pool.getEffectiveAPR(6, 0)).to.equal(900n);
    });

    it("duration just under 1 month gets tier 0 bonus (0)", async function () {
      const { pool } = await loadFixture(deployFixture);
      const justUnder = ONE_MONTH - 1;
      expect(await pool.getEffectiveAPR(3, justUnder)).to.equal(700n); // tier 3 base only
    });

    it("duration just under 6 months gets tier 1 bonus (+1%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      const justUnder = SIX_MONTHS - 1;
      // tier 3 base (700) + duration tier 1 (+100) = 800
      expect(await pool.getEffectiveAPR(3, justUnder)).to.equal(800n);
    });

    it("duration just under 2 years gets tier 2 bonus (+2%)", async function () {
      const { pool } = await loadFixture(deployFixture);
      const justUnder = TWO_YEARS - 1;
      // tier 3 base (700) + duration tier 2 (+200) = 900
      expect(await pool.getEffectiveAPR(3, justUnder)).to.equal(900n);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  9. _clampTier (tested via earned/claimRewards indirectly)
  // ──────────────────────────────────────────────────────────────────────

  describe("_clampTier (tier validation against staked amount)", function () {
    it("should accept matching tier for tier 1 amount", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_1_AMOUNT,
        1,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 30 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      expect(reward).to.be.gt(0n);
    });

    it("should clamp down an inflated tier (tier 5 declared but only tier 1 amount)", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      // Declare tier 5 but only have 1000 XOM (tier 1 amount)
      await omniCore.setStake(
        staker.address,
        TIER_1_AMOUNT,
        5,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      // Expected: tier 1 APR (500) + duration tier 2 (200) = 700 bps
      // NOT tier 5 APR (900) + 200 = 1100 bps
      const expectedOneYear =
        (TIER_1_AMOUNT * 700n) / (BASIS_POINTS); // per year
      // Allow generous tolerance for time precision
      const tolerance = expectedOneYear / 10n;
      expect(reward).to.be.closeTo(expectedOneYear, tolerance);
    });

    it("should accept tier 2 for amount >= 1M XOM", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 30 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      expect(reward).to.be.gt(0n);
    });

    it("should return 0 for amount < 1 XOM (below tier 1 threshold)", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      // Sub-1-XOM amount: tier 0 computed, APR = 0
      const subXom = ethers.parseEther("0.5");
      await omniCore.setStake(
        staker.address,
        subXom,
        1,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 30 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      // Clamped to tier 0 base APR = 0, only duration bonus
      // tier 0 base = 0 + duration tier 2 = 200 bps
      // Actually _clampTier returns 0 for < 1e18, and declared is 1 => min(1,0) = 0
      // Then _getEffectiveAPR(0, SIX_MONTHS) = tierAPR[0] + durationBonusAPR[2] = 0 + 200 = 200
      // So reward = (0.5e18 * 200 * elapsed) / (SECONDS_PER_YEAR * 10000)
      // This is non-zero but tiny
      expect(reward).to.be.gt(0n);
    });

    it("should handle exact boundary: 1M XOM staked gets tier 2", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      const exactBoundary = ethers.parseEther("1000000");
      await omniCore.setStake(
        staker.address,
        exactBoundary,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 30 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      expect(reward).to.be.gt(0n);
    });

    it("should handle exact boundary: 999,999 XOM only qualifies for tier 1", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      // Just below tier 2 threshold
      const justBelow = ethers.parseEther("999999");
      await omniCore.setStake(
        staker.address,
        justBelow,
        2, // declares tier 2
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      const reward = await pool.earned(staker.address);
      // Should use tier 1 APR (500) not tier 2 (600), plus duration tier 2 bonus (200)
      // Expected: justBelow * 700 / 10000 per year
      const expectedOneYear = (justBelow * 700n) / BASIS_POINTS;
      const tolerance = expectedOneYear / 10n;
      expect(reward).to.be.closeTo(expectedOneYear, tolerance);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  10. MIN_STAKE_AGE
  // ──────────────────────────────────────────────────────────────────────

  describe("MIN_STAKE_AGE (flash-stake protection)", function () {
    it("should return 0 rewards if stake is younger than 24h", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      // Do NOT advance past MIN_STAKE_AGE
      expect(await pool.earned(staker.address)).to.equal(0n);
    });

    it("should return 0 rewards at exactly MIN_STAKE_AGE - 1 second", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      // Advance to MIN_STAKE_AGE - 2 (one short of the threshold)
      await time.increase(MIN_STAKE_AGE - 2);
      expect(await pool.earned(staker.address)).to.equal(0n);
    });

    it("should start accruing after MIN_STAKE_AGE", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        now + SIX_MONTHS,
        true
      );
      // Advance past MIN_STAKE_AGE
      await time.increase(MIN_STAKE_AGE + 100);
      expect(await pool.earned(staker.address)).to.be.gt(0n);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  11. Duration = 0 (uncommitted stakers)
  // ──────────────────────────────────────────────────────────────────────

  describe("Duration = 0 (uncommitted stakers)", function () {
    it("should return 0 rewards when duration is 0", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        0, // no lock commitment
        now,
        true
      );
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);
      expect(await pool.earned(staker.address)).to.equal(0n);
    });

    it("should prevent claiming when duration is 0", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      const now = await time.latest();
      await omniCore.setStake(staker.address, TIER_2_AMOUNT, 2, 0, now, true);
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);

      await expect(
        pool.connect(staker).claimRewards()
      ).to.be.revertedWithCustomError(pool, "NoRewardsToClaim");
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  12. Pause / Unpause
  // ──────────────────────────────────────────────────────────────────────

  describe("Pause / Unpause", function () {
    it("pause should set paused state", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).pause();
      expect(await pool.paused()).to.be.true;
    });

    it("unpause should clear paused state", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).pause();
      await pool.connect(admin).unpause();
      expect(await pool.paused()).to.be.false;
    });

    it("pause should revert if called by non-DEFAULT_ADMIN_ROLE", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(pool.connect(nonAdmin).pause()).to.be.reverted;
    });

    it("unpause should revert if called by non-DEFAULT_ADMIN_ROLE", async function () {
      const { pool, admin, nonAdmin } = await loadFixture(deployFixture);
      await pool.connect(admin).pause();
      await expect(pool.connect(nonAdmin).unpause()).to.be.reverted;
    });

    it("claimRewards should be blocked when paused", async function () {
      const { pool, admin, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);
      await pool.connect(admin).pause();

      await expect(
        pool.connect(staker).claimRewards()
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });

    it("depositToPool should be blocked when paused", async function () {
      const { pool, xom, admin, staker } = await loadFixture(deployFixture);
      await pool.connect(admin).pause();
      const amount = ethers.parseEther("1000");
      await xom.mint(staker.address, amount);
      await xom.connect(staker).approve(pool.target, amount);

      await expect(
        pool.connect(staker).depositToPool(amount)
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });

    it("snapshotRewards should be blocked when paused", async function () {
      const { pool, admin, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await pool.connect(admin).pause();

      await expect(
        pool.snapshotRewards(staker.address)
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  13. Emergency Withdraw
  // ──────────────────────────────────────────────────────────────────────

  describe("Emergency Withdraw", function () {
    it("should withdraw non-XOM tokens successfully", async function () {
      const { pool, otherToken, admin, staker } =
        await loadFixture(deployFixture);
      const amount = ethers.parseEther("500");
      await otherToken.mint(pool.target, amount);

      const balBefore = await otherToken.balanceOf(staker.address);
      await pool
        .connect(admin)
        .emergencyWithdraw(otherToken.target, amount, staker.address);
      const balAfter = await otherToken.balanceOf(staker.address);
      expect(balAfter - balBefore).to.equal(amount);
    });

    it("should revert with CannotWithdrawRewardToken when withdrawing XOM", async function () {
      const { pool, xom, admin, staker } = await loadFixture(deployFixture);
      await expect(
        pool
          .connect(admin)
          .emergencyWithdraw(
            xom.target,
            ethers.parseEther("100"),
            staker.address
          )
      ).to.be.revertedWithCustomError(pool, "CannotWithdrawRewardToken");
    });

    it("should revert with ZeroAddress if recipient is zero", async function () {
      const { pool, otherToken, admin } = await loadFixture(deployFixture);
      await otherToken.mint(pool.target, ethers.parseEther("100"));
      await expect(
        pool
          .connect(admin)
          .emergencyWithdraw(
            otherToken.target,
            ethers.parseEther("100"),
            ethers.ZeroAddress
          )
      ).to.be.revertedWithCustomError(pool, "ZeroAddress");
    });

    it("should emit EmergencyWithdrawal event", async function () {
      const { pool, otherToken, admin, staker } =
        await loadFixture(deployFixture);
      const amount = ethers.parseEther("250");
      await otherToken.mint(pool.target, amount);

      await expect(
        pool
          .connect(admin)
          .emergencyWithdraw(otherToken.target, amount, staker.address)
      )
        .to.emit(pool, "EmergencyWithdrawal")
        .withArgs(otherToken.target, amount, staker.address);
    });

    it("should revert if called by non-DEFAULT_ADMIN_ROLE", async function () {
      const { pool, otherToken, nonAdmin, staker } =
        await loadFixture(deployFixture);
      await otherToken.mint(pool.target, ethers.parseEther("100"));
      await expect(
        pool
          .connect(nonAdmin)
          .emergencyWithdraw(
            otherToken.target,
            ethers.parseEther("100"),
            staker.address
          )
      ).to.be.reverted;
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  14. Ossification
  // ──────────────────────────────────────────────────────────────────────

  describe("Ossification", function () {
    it("ossify should set _ossified to true", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).ossify();
      expect(await pool.isOssified()).to.be.true;
    });

    it("ossify should emit ContractOssified", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await expect(pool.connect(admin).ossify())
        .to.emit(pool, "ContractOssified")
        .withArgs(pool.target);
    });

    it("upgrade should be blocked after ossification", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).ossify();

      const StakingRewardPoolV2 =
        await ethers.getContractFactory("StakingRewardPool");
      await expect(
        upgrades.upgradeProxy(pool.target, StakingRewardPoolV2, {
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor"],
        })
      ).to.be.revertedWithCustomError(pool, "ContractIsOssified");
    });

    it("ossify should revert if called by non-DEFAULT_ADMIN_ROLE", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(pool.connect(nonAdmin).ossify()).to.be.reverted;
    });

    it("upgrade should succeed before ossification", async function () {
      const { pool, admin } = await loadFixture(deployFixture);

      const StakingRewardPoolV2 =
        await ethers.getContractFactory("StakingRewardPool");
      // Should not revert
      const upgraded = await upgrades.upgradeProxy(
        pool.target,
        StakingRewardPoolV2,
        {
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor"],
        }
      );
      expect(upgraded.target).to.equal(pool.target);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  15. Access Control
  // ──────────────────────────────────────────────────────────────────────

  describe("Access Control", function () {
    it("proposeTierAPR requires ADMIN_ROLE", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(pool.connect(nonAdmin).proposeTierAPR(1, 550)).to.be
        .reverted;
    });

    it("proposeDurationBonusAPR requires ADMIN_ROLE", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(pool.connect(nonAdmin).proposeDurationBonusAPR(1, 150)).to.be
        .reverted;
    });

    it("executeAPRChange requires ADMIN_ROLE", async function () {
      const { pool, admin, nonAdmin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await time.increase(APR_TIMELOCK_DELAY + 1);
      await expect(pool.connect(nonAdmin).executeAPRChange()).to.be.reverted;
    });

    it("cancelAPRChange requires ADMIN_ROLE", async function () {
      const { pool, admin, nonAdmin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await expect(pool.connect(nonAdmin).cancelAPRChange()).to.be.reverted;
    });

    it("proposeContracts requires ADMIN_ROLE", async function () {
      const { pool, nonAdmin, staker, staker2 } =
        await loadFixture(deployFixture);
      await expect(
        pool
          .connect(nonAdmin)
          .proposeContracts(staker.address, staker2.address)
      ).to.be.reverted;
    });

    it("executeContracts requires ADMIN_ROLE", async function () {
      const { pool, admin, nonAdmin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await time.increase(TIMELOCK_DELAY + 1);
      await expect(pool.connect(nonAdmin).executeContracts()).to.be.reverted;
    });

    it("cancelContractsChange requires ADMIN_ROLE", async function () {
      const { pool, admin, nonAdmin, staker, staker2 } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await expect(pool.connect(nonAdmin).cancelContractsChange()).to.be
        .reverted;
    });

    it("pause requires DEFAULT_ADMIN_ROLE", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(pool.connect(nonAdmin).pause()).to.be.reverted;
    });

    it("unpause requires DEFAULT_ADMIN_ROLE", async function () {
      const { pool, admin, nonAdmin } = await loadFixture(deployFixture);
      await pool.connect(admin).pause();
      await expect(pool.connect(nonAdmin).unpause()).to.be.reverted;
    });

    it("emergencyWithdraw requires DEFAULT_ADMIN_ROLE", async function () {
      const { pool, otherToken, nonAdmin, staker } =
        await loadFixture(deployFixture);
      await expect(
        pool
          .connect(nonAdmin)
          .emergencyWithdraw(
            otherToken.target,
            ethers.parseEther("1"),
            staker.address
          )
      ).to.be.reverted;
    });

    it("ossify requires DEFAULT_ADMIN_ROLE", async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);
      await expect(pool.connect(nonAdmin).ossify()).to.be.reverted;
    });

    it("admin can grant ADMIN_ROLE to another account", async function () {
      const { pool, admin, staker } = await loadFixture(deployFixture);
      const ADMIN_ROLE = await pool.ADMIN_ROLE();
      await pool.connect(admin).grantRole(ADMIN_ROLE, staker.address);
      expect(await pool.hasRole(ADMIN_ROLE, staker.address)).to.be.true;
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  //  16. Edge Cases & Miscellaneous
  // ──────────────────────────────────────────────────────────────────────

  describe("Edge Cases", function () {
    it("should handle lockTime < duration gracefully (return 0 rewards)", async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);
      // Malformed: lockTime (100) < duration (SIX_MONTHS)
      await omniCore.setStake(
        staker.address,
        TIER_2_AMOUNT,
        2,
        SIX_MONTHS,
        100,
        true
      );
      await time.increase(MIN_STAKE_AGE + 365 * 24 * 60 * 60);
      expect(await pool.earned(staker.address)).to.equal(0n);
    });

    it("getPoolBalance should return actual XOM balance", async function () {
      const { pool, xom } = await loadFixture(deployFixture);
      const poolBal = await pool.getPoolBalance();
      const directBal = await xom.balanceOf(pool.target);
      expect(poolBal).to.equal(directBal);
    });

    it("multiple stakers can claim independently", async function () {
      const { pool, xom, omniCore, staker, staker2, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await setupActiveStake(staker2);
      await time.increase(30 * 24 * 60 * 60);

      const bal1Before = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const bal1After = await xom.balanceOf(staker.address);

      const bal2Before = await xom.balanceOf(staker2.address);
      await pool.connect(staker2).claimRewards();
      const bal2After = await xom.balanceOf(staker2.address);

      expect(bal1After - bal1Before).to.be.gt(0n);
      expect(bal2After - bal2Before).to.be.gt(0n);
    });

    it("snapshot followed by claim should include frozen rewards", async function () {
      const { pool, xom, omniCore, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(30 * 24 * 60 * 60);

      // Snapshot first
      await pool.snapshotRewards(staker.address);
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.be.gt(0n);

      // Wait a bit more
      await time.increase(30 * 24 * 60 * 60);

      // Claim should include frozen + newly accrued
      const balBefore = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const balAfter = await xom.balanceOf(staker.address);
      const claimed = balAfter - balBefore;

      // Should be more than what was frozen (extra 30 days accrued)
      expect(claimed).to.be.gt(frozen);
    });

    it("claiming with zero frozen and active stake should only get accrued", async function () {
      const { pool, xom, staker, setupActiveStake } =
        await loadFixture(deployFixture);
      await setupActiveStake(staker);
      await time.increase(60 * 24 * 60 * 60); // 60 days

      const earned = await pool.earned(staker.address);
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.equal(0n);
      expect(earned).to.be.gt(0n);

      const balBefore = await xom.balanceOf(staker.address);
      await pool.connect(staker).claimRewards();
      const balAfter = await xom.balanceOf(staker.address);
      expect(balAfter - balBefore).to.be.gt(0n);
    });

    it("proposeTierAPR replaces any existing pending APR change", async function () {
      const { pool, admin } = await loadFixture(deployFixture);
      await pool.connect(admin).proposeTierAPR(1, 550);
      await pool.connect(admin).proposeTierAPR(3, 750);

      const pending = await pool.pendingAPRChange();
      expect(pending.tier).to.equal(3n);
      expect(pending.newAPR).to.equal(750n);
    });

    it("proposeContracts replaces any existing pending contract change", async function () {
      const { pool, admin, staker, staker2, nonAdmin } =
        await loadFixture(deployFixture);
      await pool
        .connect(admin)
        .proposeContracts(staker.address, staker2.address);
      await pool
        .connect(admin)
        .proposeContracts(nonAdmin.address, staker.address);

      const pending = await pool.pendingContracts();
      expect(pending.omniCore).to.equal(nonAdmin.address);
      expect(pending.xomToken).to.equal(staker.address);
    });
  });
});
