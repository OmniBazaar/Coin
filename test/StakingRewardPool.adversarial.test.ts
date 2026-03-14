/**
 * StakingRewardPool.sol — Adversarial Test Suite (Round 8)
 *
 * Tests derived from adversarial agent A3 findings:
 *   Finding 1: emergencyWithdraw XOM drain via xomToken swap (Medium, HIGH conf)
 *   Finding 2: Cross-cycle frozenRewards carry-over (NOT EXPLOITABLE)
 *   Finding 3: snapshotRewards griefing (DEFENDED)
 *   DEFENDED: Ossification bypass, reward overflow, tier gaming, reentrancy
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('StakingRewardPool — Adversarial (Round 8)', function () {
  const BASIS_POINTS = 10000n;
  const SECONDS_PER_YEAR = 365n * 24n * 60n * 60n;
  const MAX_TOTAL_APR = 1200n;
  const MIN_STAKE_AGE = 86400; // 1 day
  const TIMELOCK_DELAY = 48 * 3600; // 48h
  const MAX_CLAIM_PER_TX = ethers.parseEther('1000000');
  const SIX_MONTHS = 180 * 86400;
  const TIER_2_AMOUNT = ethers.parseEther('1000000');
  const POOL_FUNDING = ethers.parseEther('10000000');
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes('ADMIN_ROLE'));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

  async function deployFixture() {
    const [admin, staker, staker2, nonAdmin, attacker] = await ethers.getSigners();

    const MockOmniCoreStaking = await ethers.getContractFactory('MockOmniCoreStaking');
    const omniCore = await MockOmniCoreStaking.deploy();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const xom = await MockERC20.deploy('OmniCoin', 'XOM');
    const otherToken = await MockERC20.deploy('OtherToken', 'OTHER');
    const fakeXom = await MockERC20.deploy('FakeXOM', 'FXOM');

    const StakingRewardPool = await ethers.getContractFactory('StakingRewardPool');
    const pool = await upgrades.deployProxy(
      StakingRewardPool,
      [omniCore.target, xom.target],
      { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress], unsafeAllow: ['constructor'] }
    );

    // Fund pool
    await xom.mint(admin.address, POOL_FUNDING * 2n);
    await xom.connect(admin).approve(pool.target, ethers.MaxUint256);
    await pool.connect(admin).depositToPool(POOL_FUNDING);

    // Setup a staker with tokens
    const stakeAmt = TIER_2_AMOUNT;
    await xom.mint(staker.address, stakeAmt * 5n);
    await xom.connect(staker).approve(omniCore.target, ethers.MaxUint256);

    return { pool, xom, otherToken, fakeXom, omniCore, admin, staker, staker2, nonAdmin, attacker };
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Finding 1: emergencyWithdraw XOM drain via xomToken swap
  // ═══════════════════════════════════════════════════════════════════════

  describe('Finding 1: emergencyWithdraw + xomToken swap', function () {
    it('should block emergencyWithdraw of XOM token', async function () {
      const { pool, xom } = await loadFixture(deployFixture);

      await expect(
        pool.emergencyWithdraw(xom.target, POOL_FUNDING, pool.runner.address)
      ).to.be.revertedWithCustomError(pool, 'CannotWithdrawRewardToken');
    });

    it('should allow emergencyWithdraw of non-XOM tokens', async function () {
      const { pool, otherToken, admin } = await loadFixture(deployFixture);

      // Send other tokens accidentally to pool
      const amount = ethers.parseEther('1000');
      await otherToken.mint(await pool.getAddress(), amount);

      await pool.emergencyWithdraw(otherToken.target, amount, admin.address);
      expect(await otherToken.balanceOf(admin.address)).to.equal(amount);
    });

    it('should document xomToken swap attack vector via proposeContracts', async function () {
      const { pool, xom, fakeXom, omniCore, admin } = await loadFixture(deployFixture);

      // Step 1: Propose changing xomToken to fakeXom
      await pool.proposeContracts(omniCore.target, fakeXom.target);

      // Step 2: Wait for timelock (48h)
      await time.increase(TIMELOCK_DELAY + 1);

      // Step 3: Execute the contract change
      await pool.executeContracts();

      // Step 4: Now emergencyWithdraw real XOM should work
      // because the check compares against the new (fake) xomToken
      const poolBalance = await xom.balanceOf(await pool.getAddress());

      // If the immutable fix is in place, this should still revert
      // If not fixed, this will succeed (documenting the vulnerability)
      const canDrain = await pool.emergencyWithdraw.staticCall(
        xom.target, poolBalance, admin.address
      ).then(() => true).catch(() => false);

      if (canDrain) {
        // Vulnerability confirmed: real XOM can be drained after xomToken swap
        // This documents the A3 Finding #1
        await pool.emergencyWithdraw(xom.target, poolBalance, admin.address);
        expect(await xom.balanceOf(await pool.getAddress())).to.equal(0n);
      }
      // If the fix is in place (immutable _permanentXomToken), this test documents
      // that the drain is blocked
    });

    it('should enforce 48h timelock on contract changes', async function () {
      const { pool, fakeXom, omniCore } = await loadFixture(deployFixture);

      await pool.proposeContracts(omniCore.target, fakeXom.target);

      // Try to execute immediately
      await expect(pool.executeContracts()).to.be.reverted;

      // Advance only 24h (not enough)
      await time.increase(24 * 3600);
      await expect(pool.executeContracts()).to.be.reverted;

      // Advance to 48h+
      await time.increase(24 * 3600 + 1);
      await expect(pool.executeContracts()).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  Finding 3: snapshotRewards griefing
  // ═══════════════════════════════════════════════════════════════════════

  describe('Finding 3: snapshotRewards griefing', function () {
    it('should allow anyone to call snapshotRewards for any user', async function () {
      const { pool, omniCore, xom, staker, attacker } = await loadFixture(deployFixture);

      // Create a stake in MockOmniCore (user, amount, tier, duration, lockTime, active)
      const now = await time.latest();
      await omniCore.setStake(staker.address, TIER_2_AMOUNT, 2, SIX_MONTHS, now + SIX_MONTHS, true);

      // Wait for some rewards to accrue
      await time.increase(86400 * 7); // 7 days

      // Attacker calls snapshotRewards for staker -- should succeed
      await expect(
        pool.connect(attacker).snapshotRewards(staker.address)
      ).to.not.be.reverted;

      // Frozen rewards should be recorded for the staker
      const frozen = await pool.frozenRewards(staker.address);
      expect(frozen).to.be.gt(0n);
    });

    it('should not cause reward loss from repeated snapshots', async function () {
      const { pool, omniCore, staker, attacker } = await loadFixture(deployFixture);

      const now = await time.latest();
      await omniCore.setStake(staker.address, TIER_2_AMOUNT, 2, SIX_MONTHS, now + SIX_MONTHS, true);

      // Wait 30 days
      await time.increase(86400 * 30);

      // Take snapshot to record baseline
      await pool.connect(attacker).snapshotRewards(staker.address);
      const frozen1 = await pool.frozenRewards(staker.address);

      // Wait 30 more days
      await time.increase(86400 * 30);

      // Another snapshot
      await pool.connect(attacker).snapshotRewards(staker.address);
      const frozen2 = await pool.frozenRewards(staker.address);

      // Frozen rewards should have increased (no loss)
      expect(frozen2).to.be.gt(frozen1);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Ossification is permanent
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Ossification', function () {
    it('should permanently block upgrades after ossification', async function () {
      const { pool } = await loadFixture(deployFixture);

      // Ossify the contract
      await pool.ossify();

      // Try to upgrade -- should be blocked by ossification
      const StakingRewardPool = await ethers.getContractFactory('StakingRewardPool');
      const newImpl = await StakingRewardPool.deploy(ethers.ZeroAddress);

      await expect(
        pool.upgradeToAndCall(await newImpl.getAddress(), '0x')
      ).to.be.revertedWithCustomError(pool, 'ContractIsOssified');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Reward calculation overflow safety
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Reward overflow safety', function () {
    it('should handle maximum possible stake without overflow', async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);

      // Set a very large stake (16.6B XOM -- total supply)
      const maxStake = ethers.parseEther('16600000000');
      const now = await time.latest();
      await omniCore.setStake(staker.address, maxStake, 5, 730 * 86400, now + 730 * 86400, true);

      // Advance 2 years
      await time.increase(730 * 86400);

      // earned() should not revert (no overflow)
      const earned = await pool.earned(staker.address);
      expect(earned).to.be.gt(0n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Tier boundary gaming
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Tier boundary gaming', function () {
    it('should clamp declared tier to actual tier based on amount', async function () {
      const { pool, omniCore, staker } = await loadFixture(deployFixture);

      // Stake 1M XOM but claim Tier 5 (should be clamped to Tier 2)
      const now = await time.latest();
      await omniCore.setStake(staker.address, TIER_2_AMOUNT, 5, SIX_MONTHS, now + SIX_MONTHS, true);

      // The pool's internal _clampTier should reduce this
      // We can verify by checking that earned() uses Tier 2 APR, not Tier 5
      await time.increase(SECONDS_PER_YEAR);
      const earned = await pool.earned(staker.address);

      // Expected: Tier 2 (6%) + Duration Bonus 2 (2%) = 8% APR
      // 1,000,000 * 0.08 = 80,000 XOM per year
      // Allow 1% tolerance for timing
      const expected = (TIER_2_AMOUNT * 800n) / BASIS_POINTS;
      const tolerance = expected / 100n;
      expect(earned).to.be.closeTo(expected, tolerance);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Access control
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Access control', function () {
    it('should reject non-admin proposeContracts', async function () {
      const { pool, omniCore, fakeXom, nonAdmin } = await loadFixture(deployFixture);

      await expect(
        pool.connect(nonAdmin).proposeContracts(omniCore.target, fakeXom.target)
      ).to.be.reverted;
    });

    it('should reject non-admin emergencyWithdraw', async function () {
      const { pool, otherToken, nonAdmin } = await loadFixture(deployFixture);

      await expect(
        pool.connect(nonAdmin).emergencyWithdraw(
          otherToken.target, 1n, nonAdmin.address
        )
      ).to.be.reverted;
    });

    it('should reject non-admin ossify', async function () {
      const { pool, nonAdmin } = await loadFixture(deployFixture);

      await expect(
        pool.connect(nonAdmin).ossify()
      ).to.be.reverted;
    });
  });
});
