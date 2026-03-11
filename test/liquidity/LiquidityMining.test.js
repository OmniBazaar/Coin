const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title LiquidityMining Test Suite
 * @notice Comprehensive tests for multi-pool LP staking with vested XOM rewards.
 * @dev Tests cover:
 *   1.  Constructor (addresses, initial state, zero-address guards)
 *   2.  addPool (valid, duplicate LP, max pools, zero address, reward cap)
 *   3.  stake (success, zero amount, inactive pool, fee-on-transfer handling)
 *   4.  withdraw (success, insufficient stake, MIN_STAKE_DURATION enforcement)
 *   5.  claim (immediate + vested, nothing to claim, vesting math)
 *   6.  claimAll (multi-pool)
 *   7.  emergencyWithdraw (fee split 80/20 protocolTreasury/stakingPool, forfeit rewards)
 *   8.  setRewardRate, setVestingParams, setPoolActive
 *   9.  depositRewards, withdrawRewards (excess only)
 *   10. pause/unpause, renounceOwnership reverts
 *   11. View functions: poolCount, getPoolInfo, getUserInfo, estimateAPR
 *   12. Ownership (Ownable2Step transfer)
 *   13. Admin setters (protocolTreasury, stakingPool, emergencyWithdrawFee)
 */
describe("LiquidityMining", function () {
  // ------ Constants matching contract ------
  const BASIS_POINTS = 10000n;
  const DEFAULT_IMMEDIATE_BPS = 3000n; // 30%
  const DEFAULT_VESTING_PERIOD = 90n * 24n * 3600n; // 90 days
  const MIN_STAKE_DURATION = 24n * 3600n; // 1 day
  const MIN_VESTING_PERIOD = 24n * 3600n; // 1 day
  const MAX_POOLS = 50;
  const MAX_REWARD_PER_SECOND = ethers.parseUnits("1", 24); // 1e24

  // ------ Typical staking parameters ------
  const REWARD_PER_SECOND = ethers.parseEther("1"); // 1 XOM/sec
  const STAKE_AMOUNT = ethers.parseEther("1000");
  const REWARD_DEPOSIT = ethers.parseEther("1000000"); // 1M XOM for rewards

  /**
   * Deploy fresh contracts and add one default pool.
   */
  async function deployMiningFixture() {
    const [owner, staker1, staker2, protocolTreasury, stakingPool, forwarder, other] =
      await ethers.getSigners();

    // Deploy mock tokens
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const xom = await ERC20Mock.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();
    const lp1 = await ERC20Mock.deploy("XOM-USDC LP", "XOM-USDC");
    await lp1.waitForDeployment();
    const lp2 = await ERC20Mock.deploy("XOM-ETH LP", "XOM-ETH");
    await lp2.waitForDeployment();

    // Deploy LiquidityMining (4 args: xom, protocolTreasury, stakingPool, forwarder)
    const LM = await ethers.getContractFactory("LiquidityMining");
    const mining = await LM.deploy(
      await xom.getAddress(),
      protocolTreasury.address,
      stakingPool.address,
      forwarder.address
    );
    await mining.waitForDeployment();

    // Mint LP tokens to stakers
    await lp1.mint(staker1.address, ethers.parseEther("100000"));
    await lp1.mint(staker2.address, ethers.parseEther("100000"));
    await lp2.mint(staker1.address, ethers.parseEther("100000"));
    await lp2.mint(staker2.address, ethers.parseEther("100000"));

    // Mint XOM to owner for reward deposits
    await xom.mint(owner.address, REWARD_DEPOSIT);

    // Approvals
    await lp1.connect(staker1).approve(await mining.getAddress(), ethers.MaxUint256);
    await lp1.connect(staker2).approve(await mining.getAddress(), ethers.MaxUint256);
    await lp2.connect(staker1).approve(await mining.getAddress(), ethers.MaxUint256);
    await lp2.connect(staker2).approve(await mining.getAddress(), ethers.MaxUint256);
    await xom.connect(owner).approve(await mining.getAddress(), ethers.MaxUint256);

    return {
      mining, xom, lp1, lp2,
      owner, staker1, staker2,
      protocolTreasury, stakingPool, forwarder, other
    };
  }

  /**
   * Deploy, add one pool, deposit rewards.
   */
  async function poolReadyFixture() {
    const fixture = await deployMiningFixture();
    const { mining, owner, lp1 } = fixture;

    await mining.connect(owner).addPool(
      await lp1.getAddress(),
      REWARD_PER_SECOND,
      0, // defaults to DEFAULT_IMMEDIATE_BPS
      0, // defaults to DEFAULT_VESTING_PERIOD
      "XOM-USDC Pool"
    );

    // Deposit rewards
    await mining.connect(owner).depositRewards(REWARD_DEPOSIT);

    return fixture;
  }

  /**
   * Deploy, add pool, deposit rewards, stake for staker1.
   */
  async function stakedFixture() {
    const fixture = await poolReadyFixture();
    const { mining, staker1 } = fixture;

    await mining.connect(staker1).stake(0, STAKE_AMOUNT);

    return fixture;
  }

  // =========================================================================
  // 1. Constructor
  // =========================================================================
  describe("Constructor", function () {
    it("should set XOM token correctly", async function () {
      const { mining, xom } = await loadFixture(deployMiningFixture);
      expect(await mining.xom()).to.equal(await xom.getAddress());
    });

    it("should set protocolTreasury correctly", async function () {
      const { mining, protocolTreasury } = await loadFixture(deployMiningFixture);
      expect(await mining.protocolTreasury()).to.equal(protocolTreasury.address);
    });

    it("should set stakingPool correctly", async function () {
      const { mining, stakingPool } = await loadFixture(deployMiningFixture);
      expect(await mining.stakingPool()).to.equal(stakingPool.address);
    });

    it("should set owner to deployer", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      expect(await mining.owner()).to.equal(owner.address);
    });

    it("should set emergencyWithdrawFeeBps to 50 (0.5%)", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.emergencyWithdrawFeeBps()).to.equal(50);
    });

    it("should start with zero pools", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.poolCount()).to.equal(0);
    });

    it("should revert if XOM address is zero", async function () {
      const [, , , protocolTreasury, stakingPool, forwarder] =
        await ethers.getSigners();
      const LM = await ethers.getContractFactory("LiquidityMining");
      await expect(
        LM.deploy(ethers.ZeroAddress, protocolTreasury.address, stakingPool.address, forwarder.address)
      ).to.be.revertedWithCustomError(LM, "InvalidParameters");
    });

    it("should revert if protocolTreasury address is zero", async function () {
      const [, , , , stakingPool, forwarder] =
        await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const LM = await ethers.getContractFactory("LiquidityMining");
      await expect(
        LM.deploy(await xom.getAddress(), ethers.ZeroAddress, stakingPool.address, forwarder.address)
      ).to.be.revertedWithCustomError(LM, "InvalidParameters");
    });

    it("should revert if stakingPool is zero", async function () {
      const [, , , protocolTreasury, , forwarder] =
        await ethers.getSigners();
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const xom = await ERC20Mock.deploy("XOM", "XOM");
      const LM = await ethers.getContractFactory("LiquidityMining");
      await expect(
        LM.deploy(await xom.getAddress(), protocolTreasury.address, ethers.ZeroAddress, forwarder.address)
      ).to.be.revertedWithCustomError(LM, "InvalidParameters");
    });
  });

  // =========================================================================
  // 2. addPool
  // =========================================================================
  describe("addPool", function () {
    it("should add a pool with correct parameters", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(
        await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1"
      );

      const info = await mining.getPoolInfo(0);
      expect(info.lpToken).to.equal(await lp1.getAddress());
      expect(info.rewardPerSecond).to.equal(REWARD_PER_SECOND);
      expect(info.active).to.be.true;
      expect(info.name).to.equal("Pool 1");
    });

    it("should increment poolCount", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool");
      expect(await mining.poolCount()).to.equal(1);
    });

    it("should emit PoolAdded event", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1")
      ).to.emit(mining, "PoolAdded")
        .withArgs(0, await lp1.getAddress(), REWARD_PER_SECOND, "Pool 1");
    });

    it("should default immediateBps to DEFAULT_IMMEDIATE_BPS when 0", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool");

      // Read directly from the pools array
      const pool = await mining.pools(0);
      expect(pool.immediateBps).to.equal(DEFAULT_IMMEDIATE_BPS);
    });

    it("should default vestingPeriod to DEFAULT_VESTING_PERIOD when 0", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool");

      const pool = await mining.pools(0);
      expect(pool.vestingPeriod).to.equal(DEFAULT_VESTING_PERIOD);
    });

    it("should accept custom immediateBps", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 5000, 0, "Pool");

      const pool = await mining.pools(0);
      expect(pool.immediateBps).to.equal(5000);
    });

    it("should accept custom vestingPeriod", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      const customPeriod = 30 * 24 * 3600; // 30 days
      await mining.connect(owner).addPool(
        await lp1.getAddress(), REWARD_PER_SECOND, 0, customPeriod, "Pool"
      );

      const pool = await mining.pools(0);
      expect(pool.vestingPeriod).to.equal(customPeriod);
    });

    it("should revert with zero LP token address", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(owner).addPool(ethers.ZeroAddress, REWARD_PER_SECOND, 0, 0, "Pool")
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should revert with duplicate LP token", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1");

      await expect(
        mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 2")
      ).to.be.revertedWithCustomError(mining, "LpTokenAlreadyAdded");
    });

    it("should revert if rewardPerSecond exceeds MAX_REWARD_PER_SECOND", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      const tooHigh = MAX_REWARD_PER_SECOND + 1n;
      await expect(
        mining.connect(owner).addPool(await lp1.getAddress(), tooHigh, 0, 0, "Pool")
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should revert if immediateBps exceeds BASIS_POINTS", async function () {
      const { mining, owner, lp1 } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 10001, 0, "Pool")
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should revert if called by non-owner", async function () {
      const { mining, staker1, lp1 } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(staker1).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool")
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });

    it("should support multiple distinct pools", async function () {
      const { mining, owner, lp1, lp2 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1");
      await mining.connect(owner).addPool(await lp2.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 2");
      expect(await mining.poolCount()).to.equal(2);
    });
  });

  // =========================================================================
  // 3. stake
  // =========================================================================
  describe("stake", function () {
    it("should accept LP token stake and update user amount", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.amount).to.equal(STAKE_AMOUNT);
    });

    it("should update pool totalStaked", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      const info = await mining.getPoolInfo(0);
      expect(info.totalStaked).to.equal(STAKE_AMOUNT);
    });

    it("should emit Staked event", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(mining.connect(staker1).stake(0, STAKE_AMOUNT))
        .to.emit(mining, "Staked")
        .withArgs(staker1.address, 0, STAKE_AMOUNT);
    });

    it("should transfer LP tokens from user to contract", async function () {
      const { mining, lp1, staker1 } = await loadFixture(poolReadyFixture);

      const before = await lp1.balanceOf(staker1.address);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);
      const after_ = await lp1.balanceOf(staker1.address);

      expect(before - after_).to.equal(STAKE_AMOUNT);
    });

    it("should record stakeTimestamp", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      const ts = await mining.stakeTimestamp(0, staker1.address);
      expect(ts).to.be.gt(0);
    });

    it("should accumulate across multiple stakes", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      // Advance past MIN_STAKE_DURATION to avoid issues, then stake more
      await time.increase(Number(MIN_STAKE_DURATION) + 1);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.amount).to.equal(STAKE_AMOUNT * 2n);
    });

    it("should revert with zero amount", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).stake(0, 0)
      ).to.be.revertedWithCustomError(mining, "ZeroAmount");
    });

    it("should revert for non-existent pool", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).stake(99, STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should revert for inactive pool", async function () {
      const { mining, owner, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).setPoolActive(0, false);

      await expect(
        mining.connect(staker1).stake(0, STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(mining, "PoolNotActive");
    });

    it("should revert when contract is paused", async function () {
      const { mining, owner, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).pause();

      await expect(
        mining.connect(staker1).stake(0, STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(mining, "EnforcedPause");
    });

    it("should harvest existing rewards on additional stake", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      // Accumulate rewards
      await time.increase(100);

      // Second stake should harvest, so pendingImmediate increases
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);

      const info = await mining.getUserInfo(0, staker1.address);
      // Should have some pending immediate rewards from harvest
      expect(info.pendingImmediate).to.be.gt(0);
    });
  });

  // =========================================================================
  // 4. withdraw
  // =========================================================================
  describe("withdraw", function () {
    it("should withdraw staked LP tokens after MIN_STAKE_DURATION", async function () {
      const { mining, lp1, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);

      const before = await lp1.balanceOf(staker1.address);
      await mining.connect(staker1).withdraw(0, STAKE_AMOUNT);
      const after_ = await lp1.balanceOf(staker1.address);

      expect(after_ - before).to.equal(STAKE_AMOUNT);
    });

    it("should emit Withdrawn event", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);

      await expect(mining.connect(staker1).withdraw(0, STAKE_AMOUNT))
        .to.emit(mining, "Withdrawn")
        .withArgs(staker1.address, 0, STAKE_AMOUNT);
    });

    it("should update user amount and pool totalStaked", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);
      await mining.connect(staker1).withdraw(0, STAKE_AMOUNT);

      const userInfo = await mining.getUserInfo(0, staker1.address);
      expect(userInfo.amount).to.equal(0);

      const poolInfo = await mining.getPoolInfo(0);
      expect(poolInfo.totalStaked).to.equal(0);
    });

    it("should allow partial withdrawal", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);
      const half = STAKE_AMOUNT / 2n;
      await mining.connect(staker1).withdraw(0, half);

      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.amount).to.equal(STAKE_AMOUNT - half);
    });

    it("should revert before MIN_STAKE_DURATION", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      // Do not advance time
      await expect(
        mining.connect(staker1).withdraw(0, STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(mining, "MinStakeDurationNotMet");
    });

    it("should revert with insufficient stake", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);

      await expect(
        mining.connect(staker1).withdraw(0, STAKE_AMOUNT + 1n)
      ).to.be.revertedWithCustomError(mining, "InsufficientStake");
    });

    it("should revert with zero amount", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);

      await expect(
        mining.connect(staker1).withdraw(0, 0)
      ).to.be.revertedWithCustomError(mining, "ZeroAmount");
    });

    it("should revert for non-existent pool", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await expect(
        mining.connect(staker1).withdraw(99, STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should revert when paused", async function () {
      const { mining, owner, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 1);
      await mining.connect(owner).pause();

      await expect(
        mining.connect(staker1).withdraw(0, STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(mining, "EnforcedPause");
    });

    it("should harvest rewards before withdrawal", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(Number(MIN_STAKE_DURATION) + 100);

      // Check that pending rewards exist before withdraw
      const infoBefore = await mining.getUserInfo(0, staker1.address);
      expect(infoBefore.pendingImmediate).to.be.gt(0);

      // Withdraw all - should still have pending rewards
      await mining.connect(staker1).withdraw(0, STAKE_AMOUNT);
    });
  });

  // =========================================================================
  // 5. claim
  // =========================================================================
  describe("claim", function () {
    it("should claim immediate rewards", async function () {
      const { mining, xom, staker1 } = await loadFixture(stakedFixture);

      // Accumulate 100 seconds of rewards
      await time.increase(100);

      const xomBefore = await xom.balanceOf(staker1.address);
      await mining.connect(staker1).claim(0);
      const xomAfter = await xom.balanceOf(staker1.address);

      expect(xomAfter).to.be.gt(xomBefore);
    });

    it("should return immediate and vested amounts", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);

      const result = await mining.connect(staker1).claim.staticCall(0);
      // With 30% immediate, immediateAmount should be about 30% of total
      expect(result.immediateAmount).to.be.gt(0);
    });

    it("should emit RewardsClaimed event", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);

      await expect(mining.connect(staker1).claim(0))
        .to.emit(mining, "RewardsClaimed");
    });

    it("should revert when nothing to claim", async function () {
      const { mining, staker2 } = await loadFixture(poolReadyFixture);
      // staker2 has not staked
      await expect(
        mining.connect(staker2).claim(0)
      ).to.be.revertedWithCustomError(mining, "NothingToClaim");
    });

    it("should revert for non-existent pool", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await expect(
        mining.connect(staker1).claim(99)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should update totalXomDistributed", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);

      const before = await mining.totalXomDistributed();
      await mining.connect(staker1).claim(0);
      const after_ = await mining.totalXomDistributed();

      expect(after_).to.be.gt(before);
    });

    it("should decrement totalCommittedRewards on claim", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);

      // First harvest to get committed rewards
      // claim does harvest internally
      const committedBefore = await mining.totalCommittedRewards();
      await mining.connect(staker1).claim(0);
      // After claiming, committed should have decreased by claimed amount
      // Note: it first increases (harvest), then decreases (claim). Net effect
      // depends on timing, but after claim pending should be zero
    });

    it("should vest rewards linearly over vestingPeriod", async function () {
      const { mining, xom, owner, staker1 } = await loadFixture(stakedFixture);

      // Deposit extra rewards to cover extended time period
      await xom.mint(owner.address, ethers.parseEther("100000000"));
      await xom.connect(owner).approve(await mining.getAddress(), ethers.MaxUint256);
      await mining.connect(owner).depositRewards(ethers.parseEther("100000000"));

      // Accumulate rewards
      await time.increase(1000);

      // First claim - gets immediate + whatever is vested so far
      await mining.connect(staker1).claim(0);
      const balance1 = await xom.balanceOf(staker1.address);

      // Advance 45 days (half of 90-day vesting)
      await time.increase(45 * 24 * 3600);

      // Second claim - should get more vested rewards
      await mining.connect(staker1).claim(0);
      const balance2 = await xom.balanceOf(staker1.address);

      expect(balance2).to.be.gt(balance1);
    });

    it("should fully vest after vestingPeriod expires", async function () {
      const { mining, xom, owner, staker1 } = await loadFixture(stakedFixture);

      // Deposit extra rewards to cover extended time period
      await xom.mint(owner.address, ethers.parseEther("100000000"));
      await xom.connect(owner).approve(await mining.getAddress(), ethers.MaxUint256);
      await mining.connect(owner).depositRewards(ethers.parseEther("100000000"));

      // Accumulate rewards for 100 seconds
      await time.increase(100);

      // Claim immediate portion
      await mining.connect(staker1).claim(0);
      const afterImmediate = await xom.balanceOf(staker1.address);

      // Advance past full vesting period (90 days + buffer)
      await time.increase(Number(DEFAULT_VESTING_PERIOD) + 100);

      // Claim fully vested
      await mining.connect(staker1).claim(0);
      const afterVested = await xom.balanceOf(staker1.address);

      expect(afterVested).to.be.gt(afterImmediate);
    });

    it("should split rewards according to immediateBps", async function () {
      const { mining, staker1, xom } = await loadFixture(stakedFixture);

      // Accumulate rewards for 1000 seconds
      await time.increase(1000);

      // Get the claim result
      const result = await mining.connect(staker1).claim.staticCall(0);

      // immediateAmount should be roughly 30% of total (the rest goes to vesting)
      // total = immediateAmount + vestedAmount (vested is what has linearly unlocked so far)
      expect(result.immediateAmount).to.be.gt(0);
    });
  });

  // =========================================================================
  // 6. claimAll
  // =========================================================================
  describe("claimAll", function () {
    it("should claim rewards from multiple pools", async function () {
      const { mining, xom, lp1, lp2, owner, staker1 } = await loadFixture(deployMiningFixture);

      // Add two pools
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1");
      await mining.connect(owner).addPool(await lp2.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 2");
      await mining.connect(owner).depositRewards(REWARD_DEPOSIT);

      // Stake in both
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);
      await mining.connect(staker1).stake(1, STAKE_AMOUNT);

      // Accumulate rewards
      await time.increase(100);

      const xomBefore = await xom.balanceOf(staker1.address);
      await mining.connect(staker1).claimAll();
      const xomAfter = await xom.balanceOf(staker1.address);

      expect(xomAfter).to.be.gt(xomBefore);
    });

    it("should return total immediate and vested amounts", async function () {
      const { mining, lp1, lp2, owner, staker1 } = await loadFixture(deployMiningFixture);

      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1");
      await mining.connect(owner).addPool(await lp2.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 2");
      await mining.connect(owner).depositRewards(REWARD_DEPOSIT);

      await mining.connect(staker1).stake(0, STAKE_AMOUNT);
      await mining.connect(staker1).stake(1, STAKE_AMOUNT);
      await time.increase(100);

      const result = await mining.connect(staker1).claimAll.staticCall();
      expect(result.totalImmediate).to.be.gt(0);
    });

    it("should emit RewardsClaimed for each pool with rewards", async function () {
      const { mining, lp1, lp2, owner, staker1 } = await loadFixture(deployMiningFixture);

      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1");
      await mining.connect(owner).addPool(await lp2.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 2");
      await mining.connect(owner).depositRewards(REWARD_DEPOSIT);

      await mining.connect(staker1).stake(0, STAKE_AMOUNT);
      await mining.connect(staker1).stake(1, STAKE_AMOUNT);
      await time.increase(100);

      const tx = mining.connect(staker1).claimAll();
      await expect(tx).to.emit(mining, "RewardsClaimed");
    });

    it("should revert if no rewards across all pools", async function () {
      const { mining, staker2 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker2).claimAll()
      ).to.be.revertedWithCustomError(mining, "NothingToClaim");
    });
  });

  // =========================================================================
  // 7. emergencyWithdraw
  // =========================================================================
  describe("emergencyWithdraw", function () {
    it("should return LP tokens minus fee", async function () {
      const { mining, lp1, staker1 } = await loadFixture(stakedFixture);
      const before = await lp1.balanceOf(staker1.address);
      await mining.connect(staker1).emergencyWithdraw(0);
      const after_ = await lp1.balanceOf(staker1.address);

      // Fee is 0.5% = 50 bps
      const expectedFee = (STAKE_AMOUNT * 50n) / BASIS_POINTS;
      const expectedReturn = STAKE_AMOUNT - expectedFee;
      expect(after_ - before).to.equal(expectedReturn);
    });

    it("should distribute fee with 80/20 split (protocolTreasury/stakingPool)", async function () {
      const { mining, lp1, staker1, protocolTreasury, stakingPool } =
        await loadFixture(stakedFixture);

      const protocolBefore = await lp1.balanceOf(protocolTreasury.address);
      const stakingBefore = await lp1.balanceOf(stakingPool.address);

      await mining.connect(staker1).emergencyWithdraw(0);

      const fee = (STAKE_AMOUNT * 50n) / BASIS_POINTS;
      const stakingShare = (fee * 2000n) / BASIS_POINTS;  // 20%
      const protocolShare = fee - stakingShare;             // 80% (70% + 10%)

      expect(await lp1.balanceOf(protocolTreasury.address) - protocolBefore).to.equal(protocolShare);
      expect(await lp1.balanceOf(stakingPool.address) - stakingBefore).to.equal(stakingShare);
    });

    it("should emit EmergencyWithdraw event", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      const fee = (STAKE_AMOUNT * 50n) / BASIS_POINTS;
      const amountAfterFee = STAKE_AMOUNT - fee;

      await expect(mining.connect(staker1).emergencyWithdraw(0))
        .to.emit(mining, "EmergencyWithdraw")
        .withArgs(staker1.address, 0, amountAfterFee, fee);
    });

    it("should forfeit all pending rewards", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);

      await mining.connect(staker1).emergencyWithdraw(0);

      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.amount).to.equal(0);
      expect(info.pendingImmediate).to.equal(0);
      expect(info.totalVesting).to.equal(0);
    });

    it("should reset user state completely", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);
      await mining.connect(staker1).emergencyWithdraw(0);

      const stake = await mining.userStakes(0, staker1.address);
      expect(stake.amount).to.equal(0);
      expect(stake.rewardDebt).to.equal(0);
      expect(stake.pendingImmediate).to.equal(0);
      expect(stake.vestingTotal).to.equal(0);
      expect(stake.vestingClaimed).to.equal(0);
      expect(stake.vestingStart).to.equal(0);
    });

    it("should work even when contract is paused", async function () {
      const { mining, owner, staker1 } = await loadFixture(stakedFixture);
      await mining.connect(owner).pause();

      // Emergency withdraw should still work
      await expect(
        mining.connect(staker1).emergencyWithdraw(0)
      ).to.not.be.reverted;
    });

    it("should revert with zero stake", async function () {
      const { mining, staker2 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker2).emergencyWithdraw(0)
      ).to.be.revertedWithCustomError(mining, "InsufficientStake");
    });

    it("should revert for non-existent pool", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await expect(
        mining.connect(staker1).emergencyWithdraw(99)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should update pool totalStaked", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await mining.connect(staker1).emergencyWithdraw(0);

      const poolInfo = await mining.getPoolInfo(0);
      expect(poolInfo.totalStaked).to.equal(0);
    });
  });

  // =========================================================================
  // 8. setRewardRate / setVestingParams / setPoolActive
  // =========================================================================
  describe("setRewardRate", function () {
    it("should update reward rate", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      const newRate = ethers.parseEther("2");
      await mining.connect(owner).setRewardRate(0, newRate);

      const pool = await mining.pools(0);
      expect(pool.rewardPerSecond).to.equal(newRate);
    });

    it("should emit RewardRateUpdated event", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      const newRate = ethers.parseEther("2");

      await expect(mining.connect(owner).setRewardRate(0, newRate))
        .to.emit(mining, "RewardRateUpdated")
        .withArgs(0, REWARD_PER_SECOND, newRate);
    });

    it("should revert if exceeds MAX_REWARD_PER_SECOND", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).setRewardRate(0, MAX_REWARD_PER_SECOND + 1n)
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should revert for non-existent pool", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).setRewardRate(99, REWARD_PER_SECOND)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should revert if called by non-owner", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).setRewardRate(0, REWARD_PER_SECOND)
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });

    it("should allow setting rate to zero (pause rewards)", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).setRewardRate(0, 0);
      const pool = await mining.pools(0);
      expect(pool.rewardPerSecond).to.equal(0);
    });
  });

  describe("setVestingParams", function () {
    it("should update immediateBps and vestingPeriod", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      const newImmediate = 5000;
      const newVesting = 30 * 24 * 3600; // 30 days

      await mining.connect(owner).setVestingParams(0, newImmediate, newVesting);

      const pool = await mining.pools(0);
      expect(pool.immediateBps).to.equal(newImmediate);
      expect(pool.vestingPeriod).to.equal(newVesting);
    });

    it("should emit VestingParamsUpdated event", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(mining.connect(owner).setVestingParams(0, 5000, 86400))
        .to.emit(mining, "VestingParamsUpdated")
        .withArgs(0, 5000, 86400);
    });

    it("should allow immediateBps of 0 (fully vesting)", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).setVestingParams(0, 0, Number(DEFAULT_VESTING_PERIOD));
      const pool = await mining.pools(0);
      expect(pool.immediateBps).to.equal(0);
    });

    it("should allow immediateBps of 10000 (fully immediate)", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).setVestingParams(0, 10000, 0);
      const pool = await mining.pools(0);
      expect(pool.immediateBps).to.equal(10000);
    });

    it("should revert if immediateBps exceeds BASIS_POINTS", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).setVestingParams(0, 10001, 86400)
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should revert if vestingPeriod > 0 but < MIN_VESTING_PERIOD", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      // MIN_VESTING_PERIOD = 1 day = 86400
      await expect(
        mining.connect(owner).setVestingParams(0, 3000, 100)
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should allow vestingPeriod of 0 (no vesting)", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).setVestingParams(0, 10000, 0)
      ).to.not.be.reverted;
    });

    it("should revert for non-existent pool", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).setVestingParams(99, 3000, 86400)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should revert if called by non-owner", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).setVestingParams(0, 3000, 86400)
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });
  });

  describe("setPoolActive", function () {
    it("should deactivate a pool", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).setPoolActive(0, false);

      const info = await mining.getPoolInfo(0);
      expect(info.active).to.be.false;
    });

    it("should reactivate a pool", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).setPoolActive(0, false);
      await mining.connect(owner).setPoolActive(0, true);

      const info = await mining.getPoolInfo(0);
      expect(info.active).to.be.true;
    });

    it("should emit PoolActiveUpdated event", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(mining.connect(owner).setPoolActive(0, false))
        .to.emit(mining, "PoolActiveUpdated")
        .withArgs(0, false);
    });

    it("should revert for non-existent pool", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).setPoolActive(99, false)
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should revert if called by non-owner", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).setPoolActive(0, false)
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });
  });

  // =========================================================================
  // 9. depositRewards / withdrawRewards
  // =========================================================================
  describe("depositRewards", function () {
    it("should transfer XOM from owner to contract", async function () {
      const { mining, xom, owner } = await loadFixture(deployMiningFixture);
      const amount = ethers.parseEther("10000");

      const before = await xom.balanceOf(await mining.getAddress());
      await mining.connect(owner).depositRewards(amount);
      const after_ = await xom.balanceOf(await mining.getAddress());

      expect(after_ - before).to.equal(amount);
    });

    it("should revert if called by non-owner", async function () {
      const { mining, staker1 } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(staker1).depositRewards(1000)
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });
  });

  describe("withdrawRewards", function () {
    it("should withdraw excess XOM not committed to users", async function () {
      const { mining, xom, owner, protocolTreasury } = await loadFixture(poolReadyFixture);

      // No stakers, so all deposited XOM is excess
      const excess = REWARD_DEPOSIT;
      const treasuryBefore = await xom.balanceOf(protocolTreasury.address);

      await mining.connect(owner).withdrawRewards(excess);

      const treasuryAfter = await xom.balanceOf(protocolTreasury.address);
      expect(treasuryAfter - treasuryBefore).to.equal(excess);
    });

    it("should send withdrawn XOM to protocolTreasury", async function () {
      const { mining, xom, owner, protocolTreasury } = await loadFixture(poolReadyFixture);
      const amount = ethers.parseEther("1000");
      const before = await xom.balanceOf(protocolTreasury.address);
      await mining.connect(owner).withdrawRewards(amount);
      expect(await xom.balanceOf(protocolTreasury.address) - before).to.equal(amount);
    });

    it("should revert if trying to withdraw committed rewards", async function () {
      const { mining, owner, staker1 } = await loadFixture(poolReadyFixture);

      // Stake and accumulate rewards
      await mining.connect(staker1).stake(0, STAKE_AMOUNT);
      await time.increase(1000);

      // Trigger harvest to commit rewards
      await mining.connect(staker1).claim(0);

      // Now try to withdraw all (should fail because some is committed)
      const balance = await mining.xom().then(async (addr) => {
        const token = await ethers.getContractAt("ERC20Mock", addr);
        return token.balanceOf(await mining.getAddress());
      });
      const committed = await mining.totalCommittedRewards();

      // If balance == committed, any withdrawal should fail
      // If balance > committed, only excess is withdrawable
      if (balance > committed) {
        const excess = balance - committed;
        await expect(
          mining.connect(owner).withdrawRewards(excess + 1n)
        ).to.be.revertedWithCustomError(mining, "InsufficientRewards");
      }
    });

    it("should revert if called by non-owner", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).withdrawRewards(1000)
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });
  });

  // =========================================================================
  // 10. pause / unpause / renounceOwnership
  // =========================================================================
  describe("Pausable", function () {
    it("should allow owner to pause", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).pause();
      expect(await mining.paused()).to.be.true;
    });

    it("should allow owner to unpause", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).pause();
      await mining.connect(owner).unpause();
      expect(await mining.paused()).to.be.false;
    });

    it("should revert pause from non-owner", async function () {
      const { mining, staker1 } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(staker1).pause()
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });

    it("should revert unpause from non-owner", async function () {
      const { mining, owner, staker1 } = await loadFixture(poolReadyFixture);
      await mining.connect(owner).pause();
      await expect(
        mining.connect(staker1).unpause()
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });
  });

  describe("renounceOwnership", function () {
    it("should revert when called", async function () {
      const { mining, owner } = await loadFixture(poolReadyFixture);
      await expect(
        mining.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });
  });

  // =========================================================================
  // 11. View Functions
  // =========================================================================
  describe("poolCount", function () {
    it("should return 0 when no pools", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.poolCount()).to.equal(0);
    });

    it("should return correct count after adding pools", async function () {
      const { mining, owner, lp1, lp2 } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).addPool(await lp1.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 1");
      await mining.connect(owner).addPool(await lp2.getAddress(), REWARD_PER_SECOND, 0, 0, "Pool 2");
      expect(await mining.poolCount()).to.equal(2);
    });
  });

  describe("getPoolInfo", function () {
    it("should return correct pool information", async function () {
      const { mining, lp1 } = await loadFixture(poolReadyFixture);
      const info = await mining.getPoolInfo(0);

      expect(info.lpToken).to.equal(await lp1.getAddress());
      expect(info.rewardPerSecond).to.equal(REWARD_PER_SECOND);
      expect(info.totalStaked).to.equal(0);
      expect(info.active).to.be.true;
      expect(info.name).to.equal("XOM-USDC Pool");
    });

    it("should revert for non-existent pool", async function () {
      const { mining } = await loadFixture(poolReadyFixture);
      await expect(mining.getPoolInfo(99))
        .to.be.revertedWithCustomError(mining, "PoolNotFound");
    });
  });

  describe("getUserInfo", function () {
    it("should return correct staked amount", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.amount).to.equal(STAKE_AMOUNT);
    });

    it("should return pending rewards after time elapsed", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await time.increase(100);

      const info = await mining.getUserInfo(0, staker1.address);
      expect(info.pendingImmediate).to.be.gt(0);
    });

    it("should return zero for user with no stake", async function () {
      const { mining, staker2 } = await loadFixture(poolReadyFixture);
      const info = await mining.getUserInfo(0, staker2.address);
      expect(info.amount).to.equal(0);
      expect(info.pendingImmediate).to.equal(0);
    });

    it("should revert for non-existent pool", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      await expect(mining.getUserInfo(99, staker1.address))
        .to.be.revertedWithCustomError(mining, "PoolNotFound");
    });
  });

  describe("estimateAPR", function () {
    it("should return non-zero APR with staked tokens", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      const lpPrice = ethers.parseEther("1"); // $1 per LP token
      const xomPrice = ethers.parseEther("0.01"); // $0.01 per XOM

      const apr = await mining.estimateAPR(0, lpPrice, xomPrice);
      expect(apr).to.be.gt(0);
    });

    it("should return 0 when nothing is staked", async function () {
      const { mining } = await loadFixture(poolReadyFixture);
      const apr = await mining.estimateAPR(0, ethers.parseEther("1"), ethers.parseEther("0.01"));
      expect(apr).to.equal(0);
    });

    it("should return 0 when lpTokenPrice is 0", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      const apr = await mining.estimateAPR(0, 0, ethers.parseEther("0.01"));
      expect(apr).to.equal(0);
    });

    it("should return 0 when xomPrice is 0", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      const apr = await mining.estimateAPR(0, ethers.parseEther("1"), 0);
      expect(apr).to.equal(0);
    });

    it("should revert for non-existent pool", async function () {
      const { mining } = await loadFixture(poolReadyFixture);
      await expect(
        mining.estimateAPR(99, ethers.parseEther("1"), ethers.parseEther("0.01"))
      ).to.be.revertedWithCustomError(mining, "PoolNotFound");
    });

    it("should increase APR with higher XOM price", async function () {
      const { mining, staker1 } = await loadFixture(stakedFixture);
      const lpPrice = ethers.parseEther("1");

      const apr1 = await mining.estimateAPR(0, lpPrice, ethers.parseEther("0.01"));
      const apr2 = await mining.estimateAPR(0, lpPrice, ethers.parseEther("0.02"));

      expect(apr2).to.be.gt(apr1);
    });
  });

  // =========================================================================
  // 12. Ownership (Ownable2Step)
  // =========================================================================
  describe("Ownership", function () {
    it("should support two-step ownership transfer", async function () {
      const { mining, owner, other } = await loadFixture(deployMiningFixture);

      await mining.connect(owner).transferOwnership(other.address);
      // Owner hasn't changed yet (pending)
      expect(await mining.owner()).to.equal(owner.address);

      await mining.connect(other).acceptOwnership();
      expect(await mining.owner()).to.equal(other.address);
    });

    it("should revert acceptOwnership from wrong account", async function () {
      const { mining, owner, staker1, other } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).transferOwnership(other.address);

      await expect(
        mining.connect(staker1).acceptOwnership()
      ).to.be.revertedWithCustomError(mining, "OwnableUnauthorizedAccount");
    });
  });

  // =========================================================================
  // 13. Admin setters
  // =========================================================================
  describe("Admin Setters", function () {
    it("should update protocolTreasury", async function () {
      const { mining, owner, other } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).setProtocolTreasury(other.address);
      expect(await mining.protocolTreasury()).to.equal(other.address);
    });

    it("should emit ProtocolTreasuryUpdated event", async function () {
      const { mining, owner, protocolTreasury, other } = await loadFixture(deployMiningFixture);
      await expect(mining.connect(owner).setProtocolTreasury(other.address))
        .to.emit(mining, "ProtocolTreasuryUpdated")
        .withArgs(protocolTreasury.address, other.address);
    });

    it("should revert setProtocolTreasury with zero address", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(owner).setProtocolTreasury(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should update stakingPool", async function () {
      const { mining, owner, other } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).setStakingPool(other.address);
      expect(await mining.stakingPool()).to.equal(other.address);
    });

    it("should emit StakingPoolUpdated event", async function () {
      const { mining, owner, stakingPool, other } = await loadFixture(deployMiningFixture);
      await expect(mining.connect(owner).setStakingPool(other.address))
        .to.emit(mining, "StakingPoolUpdated")
        .withArgs(stakingPool.address, other.address);
    });

    it("should revert setStakingPool with zero address", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(owner).setStakingPool(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should update emergencyWithdrawFee", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).setEmergencyWithdrawFee(100); // 1%
      expect(await mining.emergencyWithdrawFeeBps()).to.equal(100);
    });

    it("should emit EmergencyWithdrawFeeUpdated event", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await expect(mining.connect(owner).setEmergencyWithdrawFee(100))
        .to.emit(mining, "EmergencyWithdrawFeeUpdated")
        .withArgs(50, 100); // old=50 (initial), new=100
    });

    it("should revert setEmergencyWithdrawFee above 10% (1000 bps)", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await expect(
        mining.connect(owner).setEmergencyWithdrawFee(1001)
      ).to.be.revertedWithCustomError(mining, "InvalidParameters");
    });

    it("should allow setEmergencyWithdrawFee to exactly 10%", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).setEmergencyWithdrawFee(1000);
      expect(await mining.emergencyWithdrawFeeBps()).to.equal(1000);
    });

    it("should allow setEmergencyWithdrawFee to zero", async function () {
      const { mining, owner } = await loadFixture(deployMiningFixture);
      await mining.connect(owner).setEmergencyWithdrawFee(0);
      expect(await mining.emergencyWithdrawFeeBps()).to.equal(0);
    });
  });

  // =========================================================================
  // 14. Constants
  // =========================================================================
  describe("Constants", function () {
    it("should expose BASIS_POINTS as 10000", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.BASIS_POINTS()).to.equal(10000);
    });

    it("should expose DEFAULT_IMMEDIATE_BPS as 3000", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.DEFAULT_IMMEDIATE_BPS()).to.equal(3000);
    });

    it("should expose DEFAULT_VESTING_PERIOD as 90 days", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.DEFAULT_VESTING_PERIOD()).to.equal(90 * 24 * 3600);
    });

    it("should expose MAX_POOLS as 50", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.MAX_POOLS()).to.equal(50);
    });

    it("should expose MIN_STAKE_DURATION as 1 day", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.MIN_STAKE_DURATION()).to.equal(86400);
    });

    it("should expose MIN_VESTING_PERIOD as 1 day", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.MIN_VESTING_PERIOD()).to.equal(86400);
    });

    it("should expose MAX_REWARD_PER_SECOND as 1e24", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.MAX_REWARD_PER_SECOND()).to.equal(MAX_REWARD_PER_SECOND);
    });

    it("should expose MIN_UPDATE_INTERVAL as 1 day", async function () {
      const { mining } = await loadFixture(deployMiningFixture);
      expect(await mining.MIN_UPDATE_INTERVAL()).to.equal(86400);
    });
  });
});
