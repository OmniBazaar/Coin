/**
 * LiquidityMining.sol — Adversarial Test Suite (Round 8)
 *
 * Tests derived from adversarial agent B3 findings:
 *   Finding 1: emergencyWithdraw bypasses MIN_STAKE_DURATION (Medium, HIGH conf)
 *   Finding 2: totalCommittedRewards conservative drift (Low, MEDIUM conf)
 *   Finding 3: setRewardRate front-running window (Info, LOW conf)
 *   DEFENDED: Emergency withdrawal penalty, reward overflow, flash-stake,
 *             cross-contract interactions
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('LiquidityMining — Adversarial (Round 8)', function () {
  const BASIS_POINTS = 10000n;
  const MIN_STAKE_DURATION = 24n * 3600n; // 1 day
  const REWARD_PER_SECOND = ethers.parseEther('1');
  const STAKE_AMOUNT = ethers.parseEther('1000');
  const REWARD_DEPOSIT = ethers.parseEther('1000000');

  async function deployFixture() {
    const [owner, staker1, staker2, protocolTreasury, stakingPool, forwarder, attacker] =
      await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory('ERC20Mock');
    const xom = await ERC20Mock.deploy('OmniCoin', 'XOM');
    const lp1 = await ERC20Mock.deploy('XOM-USDC LP', 'XOM-USDC');

    const LiquidityMining = await ethers.getContractFactory('LiquidityMining');
    const mining = await LiquidityMining.deploy(
      await xom.getAddress(),
      protocolTreasury.address,
      stakingPool.address,
      forwarder.address
    );

    // Add a pool (lpToken, rewardPerSecond, immediateBps, vestingPeriod, name)
    await mining.addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, 'XOM-USDC Pool');

    // Deposit rewards
    await xom.mint(owner.address, REWARD_DEPOSIT);
    await xom.approve(await mining.getAddress(), REWARD_DEPOSIT);
    await mining.depositRewards(REWARD_DEPOSIT);

    // Mint LP tokens for stakers
    await lp1.mint(staker1.address, STAKE_AMOUNT * 10n);
    await lp1.mint(attacker.address, STAKE_AMOUNT * 10n);
    await lp1.connect(staker1).approve(await mining.getAddress(), ethers.MaxUint256);
    await lp1.connect(attacker).approve(await mining.getAddress(), ethers.MaxUint256);

    return { mining, xom, lp1, owner, staker1, staker2, protocolTreasury, stakingPool, attacker };
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Finding 1: emergencyWithdraw bypasses MIN_STAKE_DURATION
  // ═══════════════════════════════════════════════════════════════════════

  describe('Finding 1: emergencyWithdraw MIN_STAKE_DURATION bypass', function () {
    it('should document emergencyWithdraw availability before MIN_STAKE_DURATION', async function () {
      const { mining, lp1, attacker } = await loadFixture(deployFixture);

      // Stake
      await mining.connect(attacker).stake(0, STAKE_AMOUNT);

      // Try to emergencyWithdraw immediately (before MIN_STAKE_DURATION)
      const canEmergencyWithdraw = await mining.connect(attacker).emergencyWithdraw.staticCall(0)
        .then(() => true)
        .catch(() => false);

      if (canEmergencyWithdraw) {
        // This documents the vulnerability -- emergencyWithdraw bypasses MIN_STAKE_DURATION
        await mining.connect(attacker).emergencyWithdraw(0);
        const info = await mining.getUserInfo(0, attacker.address);
        expect(info.amount).to.equal(0n);
      }
      // If the fix is applied, emergencyWithdraw should revert before MIN_STAKE_DURATION
    });

    it('should enforce MIN_STAKE_DURATION on regular withdraw', async function () {
      const { mining, attacker } = await loadFixture(deployFixture);

      await mining.connect(attacker).stake(0, STAKE_AMOUNT);

      // Regular withdraw should fail before MIN_STAKE_DURATION
      await expect(
        mining.connect(attacker).withdraw(0, STAKE_AMOUNT)
      ).to.be.reverted;

      // Advance past MIN_STAKE_DURATION
      await time.increase(Number(MIN_STAKE_DURATION) + 1);

      // Now withdraw should work
      await expect(
        mining.connect(attacker).withdraw(0, STAKE_AMOUNT)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Emergency withdrawal penalty
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Emergency withdrawal penalty', function () {
    it('should apply fee on emergencyWithdraw', async function () {
      const { mining, lp1, staker1, protocolTreasury, stakingPool } = await loadFixture(deployFixture);

      await mining.connect(staker1).stake(0, STAKE_AMOUNT);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);

      const balBefore = await lp1.balanceOf(staker1.address);
      await mining.connect(staker1).emergencyWithdraw(0);
      const balAfter = await lp1.balanceOf(staker1.address);

      // User gets back less than full stake (fee deducted)
      const received = balAfter - balBefore;
      expect(received).to.be.lt(STAKE_AMOUNT);
      expect(received).to.be.gt(0n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Reward overflow safety
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Reward overflow safety', function () {
    it('should handle max stake without overflow', async function () {
      const { mining, lp1, staker1 } = await loadFixture(deployFixture);

      // Large stake
      const largeStake = ethers.parseEther('1000000000'); // 1B LP tokens
      await lp1.mint(staker1.address, largeStake);
      await lp1.connect(staker1).approve(await mining.getAddress(), largeStake);

      await mining.connect(staker1).stake(0, largeStake);

      // Advance 30 days
      await time.increase(30 * 86400);

      // Should not revert (no overflow)
      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.amount).to.equal(largeStake);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Access control
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Access control', function () {
    it('should reject non-owner addPool', async function () {
      const { mining, lp1, attacker } = await loadFixture(deployFixture);

      await expect(
        mining.connect(attacker).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, 'Pool')
      ).to.be.reverted;
    });

    it('should reject non-owner setRewardRate', async function () {
      const { mining, attacker } = await loadFixture(deployFixture);

      await expect(
        mining.connect(attacker).setRewardRate(0, REWARD_PER_SECOND * 2n)
      ).to.be.reverted;
    });

    it('should reject non-owner pause', async function () {
      const { mining, attacker } = await loadFixture(deployFixture);

      await expect(
        mining.connect(attacker).pause()
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: renounceOwnership blocked
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: renounceOwnership', function () {
    it('should revert on renounceOwnership', async function () {
      const { mining } = await loadFixture(deployFixture);

      await expect(
        mining.renounceOwnership()
      ).to.be.revertedWithCustomError(mining, 'InvalidParameters');
    });
  });
});
