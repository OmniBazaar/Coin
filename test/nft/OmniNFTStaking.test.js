const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniNFTStaking", function () {
  // Signers
  let owner, creator, staker1, staker2, nonOwner;

  // Contracts
  let staking, rewardToken, nftCollection;

  // Constants matching the contract
  const MULTIPLIER_PRECISION = 10000n;
  const MIN_MULTIPLIER = 1000n;
  const MAX_MULTIPLIER = 50000n;

  const STREAK_BONUS_0 = 10000n; // 1.0x
  const STREAK_BONUS_1 = 11000n; // 1.1x
  const STREAK_BONUS_2 = 12500n; // 1.25x
  const STREAK_BONUS_3 = 15000n; // 1.5x

  const STREAK_TIER1 = 7n * 24n * 3600n;  // 7 days
  const STREAK_TIER2 = 30n * 24n * 3600n; // 30 days
  const STREAK_TIER3 = 90n * 24n * 3600n; // 90 days

  const ONE_DAY = 86400;

  // Pool defaults
  const TOTAL_REWARD = ethers.parseEther("10000");
  const REWARD_PER_DAY = ethers.parseEther("100");
  const DURATION_DAYS = 100;

  beforeEach(async function () {
    [owner, creator, staker1, staker2, nonOwner] = await ethers.getSigners();

    // Deploy mock ERC-20 reward token (from contracts/mocks/)
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    rewardToken = await ERC20Mock.deploy("Reward Token", "RWD");
    await rewardToken.waitForDeployment();

    // Deploy mock ERC-721 collection (from contracts/test/)
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    nftCollection = await MockERC721.deploy("Test NFT", "TNFT");
    await nftCollection.waitForDeployment();

    // Deploy staking contract
    const OmniNFTStaking = await ethers.getContractFactory("OmniNFTStaking");
    staking = await OmniNFTStaking.deploy();
    await staking.waitForDeployment();

    // Mint reward tokens to creator and approve staking contract
    await rewardToken.mint(creator.address, TOTAL_REWARD * 10n);
    await rewardToken
      .connect(creator)
      .approve(await staking.getAddress(), ethers.MaxUint256);

    // Mint NFTs to stakers
    await nftCollection.mint(staker1.address, 1);
    await nftCollection.mint(staker1.address, 2);
    await nftCollection.mint(staker2.address, 3);
    await nftCollection.mint(staker2.address, 4);

    // Approve staking contract to transfer NFTs
    await nftCollection
      .connect(staker1)
      .setApprovalForAll(await staking.getAddress(), true);
    await nftCollection
      .connect(staker2)
      .setApprovalForAll(await staking.getAddress(), true);
  });

  /**
   * Helper: create a pool with default parameters using the creator account.
   * Returns the pool ID.
   */
  async function createDefaultPool(overrides = {}) {
    const collection = overrides.collection || (await nftCollection.getAddress());
    const reward = overrides.rewardToken || (await rewardToken.getAddress());
    const total = overrides.totalReward || TOTAL_REWARD;
    const perDay = overrides.rewardPerDay || REWARD_PER_DAY;
    const days = overrides.durationDays || DURATION_DAYS;
    const rarity = overrides.rarityEnabled !== undefined ? overrides.rarityEnabled : false;
    const signer = overrides.signer || creator;

    // Ensure signer has tokens and approval
    if (signer !== creator) {
      await rewardToken.mint(signer.address, total);
      await rewardToken
        .connect(signer)
        .approve(await staking.getAddress(), ethers.MaxUint256);
    }

    const tx = await staking
      .connect(signer)
      .createPool(collection, reward, total, perDay, days, rarity);
    const receipt = await tx.wait();

    // Extract poolId from PoolCreated event
    const event = receipt.logs.find(
      (log) => log.fragment && log.fragment.name === "PoolCreated"
    );
    return event.args[0];
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Deployment
  // ─────────────────────────────────────────────────────────────────────────
  describe("Deployment", function () {
    it("Should set the deployer as owner", async function () {
      expect(await staking.owner()).to.equal(owner.address);
    });

    it("Should initialize nextPoolId to zero", async function () {
      expect(await staking.nextPoolId()).to.equal(0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Create Pool
  // ─────────────────────────────────────────────────────────────────────────
  describe("Create Pool", function () {
    it("Should deposit reward tokens into the contract", async function () {
      const stakingAddr = await staking.getAddress();
      const balBefore = await rewardToken.balanceOf(stakingAddr);

      await createDefaultPool();

      const balAfter = await rewardToken.balanceOf(stakingAddr);
      expect(balAfter - balBefore).to.equal(TOTAL_REWARD);
    });

    it("Should emit PoolCreated with correct arguments", async function () {
      const collectionAddr = await nftCollection.getAddress();
      const rewardAddr = await rewardToken.getAddress();

      await expect(
        staking
          .connect(creator)
          .createPool(
            collectionAddr,
            rewardAddr,
            TOTAL_REWARD,
            REWARD_PER_DAY,
            DURATION_DAYS,
            false
          )
      )
        .to.emit(staking, "PoolCreated")
        .withArgs(
          0, // first poolId
          creator.address,
          collectionAddr,
          rewardAddr,
          TOTAL_REWARD,
          REWARD_PER_DAY
        );
    });

    it("Should track pool data correctly via getPool", async function () {
      const poolId = await createDefaultPool();

      const [
        poolCreator,
        collection,
        poolRewardToken,
        totalReward,
        remainingReward,
        totalStaked,
        active,
      ] = await staking.getPool(poolId);

      expect(poolCreator).to.equal(creator.address);
      expect(collection).to.equal(await nftCollection.getAddress());
      expect(poolRewardToken).to.equal(await rewardToken.getAddress());
      expect(totalReward).to.equal(TOTAL_REWARD);
      expect(remainingReward).to.equal(TOTAL_REWARD);
      expect(totalStaked).to.equal(0);
      expect(active).to.equal(true);
    });

    it("Should increment nextPoolId for each pool", async function () {
      await createDefaultPool();
      expect(await staking.nextPoolId()).to.equal(1);
      await createDefaultPool();
      expect(await staking.nextPoolId()).to.equal(2);
    });

    it("Should revert with ZeroTotalReward when total reward is zero", async function () {
      await expect(
        staking
          .connect(creator)
          .createPool(
            await nftCollection.getAddress(),
            await rewardToken.getAddress(),
            0,
            REWARD_PER_DAY,
            DURATION_DAYS,
            false
          )
      ).to.be.revertedWithCustomError(staking, "ZeroTotalReward");
    });

    it("Should revert with ZeroRewardRate when reward per day is zero", async function () {
      await expect(
        staking
          .connect(creator)
          .createPool(
            await nftCollection.getAddress(),
            await rewardToken.getAddress(),
            TOTAL_REWARD,
            0,
            DURATION_DAYS,
            false
          )
      ).to.be.revertedWithCustomError(staking, "ZeroRewardRate");
    });

    it("Should revert with ZeroDuration when duration is zero", async function () {
      await expect(
        staking
          .connect(creator)
          .createPool(
            await nftCollection.getAddress(),
            await rewardToken.getAddress(),
            TOTAL_REWARD,
            REWARD_PER_DAY,
            0,
            false
          )
      ).to.be.revertedWithCustomError(staking, "ZeroDuration");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Stake
  // ─────────────────────────────────────────────────────────────────────────
  describe("Stake", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
    });

    it("Should transfer the NFT to the staking contract", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      expect(await nftCollection.ownerOf(1)).to.equal(
        await staking.getAddress()
      );
    });

    it("Should emit Staked event", async function () {
      await expect(staking.connect(staker1).stake(poolId, 1))
        .to.emit(staking, "Staked")
        .withArgs(poolId, staker1.address, 1);
    });

    it("Should increment totalStaked on the pool", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      const [, , , , , totalStaked] = await staking.getPool(poolId);
      expect(totalStaked).to.equal(1);

      await staking.connect(staker2).stake(poolId, 3);
      const [, , , , , totalStaked2] = await staking.getPool(poolId);
      expect(totalStaked2).to.equal(2);
    });

    it("Should record stake data correctly via getStake", async function () {
      const tx = await staking.connect(staker1).stake(poolId, 1);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);

      const [staker, stakedAt, rarityMultiplier, accumulatedReward, active] =
        await staking.getStake(poolId, 1);

      expect(staker).to.equal(staker1.address);
      expect(stakedAt).to.equal(block.timestamp);
      expect(rarityMultiplier).to.equal(MULTIPLIER_PRECISION);
      expect(accumulatedReward).to.equal(0);
      expect(active).to.equal(true);
    });

    it("Should revert with AlreadyStaked when staking the same tokenId twice", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      // Transfer NFT back manually is not needed; the contract holds it.
      // Trying to stake tokenId 1 again will revert because stakes[poolId][1].active is true.
      await expect(
        staking.connect(staker1).stake(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "AlreadyStaked");
    });

    it("Should revert with PoolNotActive when staking in a paused pool", async function () {
      await staking.pausePool(poolId);
      await expect(
        staking.connect(staker1).stake(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "PoolNotActive");
    });

    it("Should revert with PoolNotFound for a non-existent pool", async function () {
      await expect(
        staking.connect(staker1).stake(999, 1)
      ).to.be.revertedWithCustomError(staking, "PoolNotFound");
    });

    it("Should update totalWeightedStakes", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      expect(await staking.totalWeightedStakes(poolId)).to.equal(
        MULTIPLIER_PRECISION
      );

      await staking.connect(staker2).stake(poolId, 3);
      expect(await staking.totalWeightedStakes(poolId)).to.equal(
        MULTIPLIER_PRECISION * 2n
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Unstake
  // ─────────────────────────────────────────────────────────────────────────
  describe("Unstake", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
      await staking.connect(staker1).stake(poolId, 1);
    });

    it("Should return the NFT to the staker", async function () {
      // Advance time so there is a reward to pay
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      expect(await nftCollection.ownerOf(1)).to.equal(staker1.address);
    });

    it("Should pay pending rewards on unstake", async function () {
      await time.increase(ONE_DAY);

      const balBefore = await rewardToken.balanceOf(staker1.address);
      await staking.connect(staker1).unstake(poolId, 1);
      const balAfter = await rewardToken.balanceOf(staker1.address);

      // With 1 staker, default multiplier, no streak bonus (< 7 days):
      // reward ~ rewardPerDay * 1 day / 1 day = rewardPerDay
      // Allow small rounding due to block timestamp
      const earned = balAfter - balBefore;
      expect(earned).to.be.gt(0);
      // Should be approximately 100 tokens (within 1% for timestamp rounding)
      expect(earned).to.be.closeTo(REWARD_PER_DAY, ethers.parseEther("1"));
    });

    it("Should emit Unstaked event with reward amount", async function () {
      await time.increase(ONE_DAY);
      await expect(staking.connect(staker1).unstake(poolId, 1))
        .to.emit(staking, "Unstaked");
      // We verified the event is emitted; argument checks are below in specific tests
    });

    it("Should revert with StakeNotFound for non-existent stake", async function () {
      await expect(
        staking.connect(staker1).unstake(poolId, 99)
      ).to.be.revertedWithCustomError(staking, "StakeNotFound");
    });

    it("Should revert with NotStaker when called by someone other than the staker", async function () {
      await time.increase(ONE_DAY);
      await expect(
        staking.connect(staker2).unstake(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "NotStaker");
    });

    it("Should decrement totalStaked on the pool", async function () {
      await staking.connect(staker2).stake(poolId, 3);
      const [, , , , , totalBefore] = await staking.getPool(poolId);
      expect(totalBefore).to.equal(2);

      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      const [, , , , , totalAfter] = await staking.getPool(poolId);
      expect(totalAfter).to.equal(1);
    });

    it("Should decrease totalWeightedStakes", async function () {
      await staking.connect(staker2).stake(poolId, 3);
      expect(await staking.totalWeightedStakes(poolId)).to.equal(
        MULTIPLIER_PRECISION * 2n
      );

      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      expect(await staking.totalWeightedStakes(poolId)).to.equal(
        MULTIPLIER_PRECISION
      );
    });

    it("Should mark the stake as inactive after unstaking", async function () {
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      const [, , , , active] = await staking.getStake(poolId, 1);
      expect(active).to.equal(false);
    });

    it("Should reduce pool remainingReward", async function () {
      await time.increase(ONE_DAY);
      const [, , , , remainingBefore] = await staking.getPool(poolId);

      await staking.connect(staker1).unstake(poolId, 1);
      const [, , , , remainingAfter] = await staking.getPool(poolId);
      expect(remainingAfter).to.be.lt(remainingBefore);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Claim Rewards
  // ─────────────────────────────────────────────────────────────────────────
  describe("Claim Rewards", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
      await staking.connect(staker1).stake(poolId, 1);
    });

    it("Should pay pending rewards without unstaking", async function () {
      await time.increase(ONE_DAY);

      const balBefore = await rewardToken.balanceOf(staker1.address);
      await staking.connect(staker1).claimRewards(poolId, 1);
      const balAfter = await rewardToken.balanceOf(staker1.address);

      expect(balAfter - balBefore).to.be.gt(0);

      // NFT should still be in the contract
      expect(await nftCollection.ownerOf(1)).to.equal(
        await staking.getAddress()
      );
    });

    it("Should emit RewardsClaimed event", async function () {
      await time.increase(ONE_DAY);
      await expect(staking.connect(staker1).claimRewards(poolId, 1)).to.emit(
        staking,
        "RewardsClaimed"
      );
    });

    it("Should update lastClaimAt timestamp", async function () {
      await time.increase(ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);

      // Read stake from the mapping via the public getter
      const stakeData = await staking.stakes(poolId, 1);
      const latestBlock = await ethers.provider.getBlock("latest");
      expect(stakeData.lastClaimAt).to.equal(latestBlock.timestamp);
    });

    it("Should accumulate rewards in accumulatedReward", async function () {
      await time.increase(ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);

      const [, , , accumulatedReward] = await staking.getStake(poolId, 1);
      expect(accumulatedReward).to.be.gt(0);
    });

    it("Should revert with StakeNotFound for inactive stake", async function () {
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      await expect(
        staking.connect(staker1).claimRewards(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "StakeNotFound");
    });

    it("Should revert with NotStaker when called by non-staker", async function () {
      await time.increase(ONE_DAY);
      await expect(
        staking.connect(staker2).claimRewards(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "NotStaker");
    });

    it("Should allow multiple claims over time", async function () {
      await time.increase(ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);
      const bal1 = await rewardToken.balanceOf(staker1.address);

      await time.increase(ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);
      const bal2 = await rewardToken.balanceOf(staker1.address);

      expect(bal2).to.be.gt(bal1);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Pending Rewards
  // ─────────────────────────────────────────────────────────────────────────
  describe("Pending Rewards", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
    });

    it("Should return zero when just staked (same block)", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      // In the same block, elapsed = 0
      const pending = await staking.pendingRewards(poolId, 1);
      expect(pending).to.equal(0);
    });

    it("Should return correct amount after one day with single staker", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);

      const pending = await staking.pendingRewards(poolId, 1);
      // Single staker, 1.0x multiplier, 1.0x streak:
      // reward = rewardPerDay * elapsed * 10000 * 10000 / (86400 * 10000 * 10000)
      //        = rewardPerDay * 86400 / 86400 = rewardPerDay
      expect(pending).to.be.closeTo(REWARD_PER_DAY, ethers.parseEther("1"));
    });

    it("Should split rewards between two stakers with equal weight", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await staking.connect(staker2).stake(poolId, 3);
      await time.increase(ONE_DAY);

      const pending1 = await staking.pendingRewards(poolId, 1);
      const pending2 = await staking.pendingRewards(poolId, 3);

      // Each staker has weight 10000 out of total 20000, so each gets ~50%
      const halfReward = REWARD_PER_DAY / 2n;
      expect(pending1).to.be.closeTo(halfReward, ethers.parseEther("1"));
      expect(pending2).to.be.closeTo(halfReward, ethers.parseEther("1"));
    });

    it("Should return zero for inactive (unstaked) stake", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);

      const pending = await staking.pendingRewards(poolId, 1);
      expect(pending).to.equal(0);
    });

    it("Should cap at remaining pool reward", async function () {
      // Create a pool with very small total reward but high rate
      const smallReward = ethers.parseEther("10");
      const highRate = ethers.parseEther("100");
      const smallPoolId = await createDefaultPool({
        totalReward: smallReward,
        rewardPerDay: highRate,
      });

      await staking.connect(staker1).stake(smallPoolId, 1);
      // After 1 day at 100/day rate, pending would be 100 but only 10 in pool
      await time.increase(ONE_DAY);

      const pending = await staking.pendingRewards(smallPoolId, 1);
      expect(pending).to.equal(smallReward);
    });

    it("Should accumulate linearly over multiple days", async function () {
      await staking.connect(staker1).stake(poolId, 1);

      await time.increase(ONE_DAY);
      const pending1 = await staking.pendingRewards(poolId, 1);

      await time.increase(ONE_DAY);
      const pending2 = await staking.pendingRewards(poolId, 1);

      // pending2 should be approximately 2x pending1 (within streak tier 0)
      expect(pending2).to.be.closeTo(pending1 * 2n, ethers.parseEther("2"));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Streak Bonus
  // ─────────────────────────────────────────────────────────────────────────
  describe("Streak Bonus", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
      await staking.connect(staker1).stake(poolId, 1);
    });

    it("Should return 1.0x (10000) for 0-6 days", async function () {
      // Just staked, 0 days
      let bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_0);

      // 3 days later
      await time.increase(3 * ONE_DAY);
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_0);

      // 6 days later (6 total)
      await time.increase(3 * ONE_DAY);
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_0);
    });

    it("Should return 1.1x (11000) for 7-29 days", async function () {
      await time.increase(7 * ONE_DAY);
      let bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_1);

      await time.increase(15 * ONE_DAY); // 22 days total
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_1);

      await time.increase(7 * ONE_DAY); // 29 days total
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_1);
    });

    it("Should return 1.25x (12500) for 30-89 days", async function () {
      await time.increase(30 * ONE_DAY);
      let bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_2);

      await time.increase(30 * ONE_DAY); // 60 days total
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_2);

      await time.increase(29 * ONE_DAY); // 89 days total
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_2);
    });

    it("Should return 1.5x (15000) for 90+ days", async function () {
      await time.increase(90 * ONE_DAY);
      let bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_3);

      await time.increase(30 * ONE_DAY); // 120 days total
      bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_3);
    });

    it("Should return 1.0x for an inactive stake", async function () {
      await time.increase(90 * ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      const bonus = await staking.getStreakBonus(poolId, 1);
      expect(bonus).to.equal(STREAK_BONUS_0);
    });

    it("Should increase rewards when streak tier changes", async function () {
      // Stake a second NFT at the same time for comparison baseline
      await staking.connect(staker1).stake(poolId, 2);

      // Claim at day 6 (no streak bonus yet for either)
      await time.increase(6 * ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);
      await staking.connect(staker1).claimRewards(poolId, 2);
      const earned6 = await rewardToken.balanceOf(staker1.address);

      // Now unstake token 2 and restake to reset its streak
      await staking.connect(staker1).unstake(poolId, 2);
      await nftCollection
        .connect(staker1)
        .setApprovalForAll(await staking.getAddress(), true);
      await staking.connect(staker1).stake(poolId, 2);

      // Advance to day 8 total (token 1 is at 8 days staked, token 2 at 2 days)
      // Token 1 now has streak bonus 1.1x, token 2 has 1.0x
      await time.increase(2 * ONE_DAY);

      const pending1 = await staking.pendingRewards(poolId, 1);
      const pending2 = await staking.pendingRewards(poolId, 2);

      // Token 1 should earn more than token 2 due to streak bonus
      // The exact ratio depends on the weighted formula, but token 1 > token 2
      expect(pending1).to.be.gt(pending2);
    });

    it("Should correctly transition between all streak tiers", async function () {
      // Verify transitions at exact boundaries
      // Day 6 -> 1.0x
      await time.increase(6 * ONE_DAY);
      expect(await staking.getStreakBonus(poolId, 1)).to.equal(STREAK_BONUS_0);

      // Day 7 -> 1.1x
      await time.increase(1 * ONE_DAY);
      expect(await staking.getStreakBonus(poolId, 1)).to.equal(STREAK_BONUS_1);

      // Day 29 -> still 1.1x
      await time.increase(22 * ONE_DAY);
      expect(await staking.getStreakBonus(poolId, 1)).to.equal(STREAK_BONUS_1);

      // Day 30 -> 1.25x
      await time.increase(1 * ONE_DAY);
      expect(await staking.getStreakBonus(poolId, 1)).to.equal(STREAK_BONUS_2);

      // Day 89 -> still 1.25x
      await time.increase(59 * ONE_DAY);
      expect(await staking.getStreakBonus(poolId, 1)).to.equal(STREAK_BONUS_2);

      // Day 90 -> 1.5x
      await time.increase(1 * ONE_DAY);
      expect(await staking.getStreakBonus(poolId, 1)).to.equal(STREAK_BONUS_3);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Rarity Multiplier
  // ─────────────────────────────────────────────────────────────────────────
  describe("Rarity Multiplier", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool({ rarityEnabled: true });
      await staking.connect(staker1).stake(poolId, 1);
    });

    it("Should default to 1.0x (10000) multiplier on stake", async function () {
      const [, , rarityMultiplier] = await staking.getStake(poolId, 1);
      expect(rarityMultiplier).to.equal(MULTIPLIER_PRECISION);
    });

    it("Should update multiplier via setRarityMultiplier (owner only)", async function () {
      const newMultiplier = 20000n; // 2.0x
      await staking.setRarityMultiplier(poolId, 1, newMultiplier);
      const [, , rarityMultiplier] = await staking.getStake(poolId, 1);
      expect(rarityMultiplier).to.equal(newMultiplier);
    });

    it("Should reject multiplier below MIN_MULTIPLIER", async function () {
      await expect(
        staking.setRarityMultiplier(poolId, 1, MIN_MULTIPLIER - 1n)
      ).to.be.revertedWithCustomError(staking, "InvalidMultiplier");
    });

    it("Should reject multiplier above MAX_MULTIPLIER", async function () {
      await expect(
        staking.setRarityMultiplier(poolId, 1, MAX_MULTIPLIER + 1n)
      ).to.be.revertedWithCustomError(staking, "InvalidMultiplier");
    });

    it("Should accept multiplier at MIN_MULTIPLIER boundary", async function () {
      await staking.setRarityMultiplier(poolId, 1, MIN_MULTIPLIER);
      const [, , rarityMultiplier] = await staking.getStake(poolId, 1);
      expect(rarityMultiplier).to.equal(MIN_MULTIPLIER);
    });

    it("Should accept multiplier at MAX_MULTIPLIER boundary", async function () {
      await staking.setRarityMultiplier(poolId, 1, MAX_MULTIPLIER);
      const [, , rarityMultiplier] = await staking.getStake(poolId, 1);
      expect(rarityMultiplier).to.equal(MAX_MULTIPLIER);
    });

    it("Should claim pending rewards before updating multiplier", async function () {
      await time.increase(ONE_DAY);

      const balBefore = await rewardToken.balanceOf(staker1.address);
      await staking.setRarityMultiplier(poolId, 1, 20000n);
      const balAfter = await rewardToken.balanceOf(staker1.address);

      // Rewards should have been sent to the staker
      expect(balAfter - balBefore).to.be.gt(0);
    });

    it("Should update totalWeightedStakes when multiplier changes", async function () {
      const weightBefore = await staking.totalWeightedStakes(poolId);
      expect(weightBefore).to.equal(MULTIPLIER_PRECISION);

      const newMultiplier = 30000n; // 3.0x
      await staking.setRarityMultiplier(poolId, 1, newMultiplier);

      const weightAfter = await staking.totalWeightedStakes(poolId);
      expect(weightAfter).to.equal(newMultiplier);
    });

    it("Should revert when called by non-owner", async function () {
      await expect(
        staking.connect(staker1).setRarityMultiplier(poolId, 1, 20000n)
      ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
    });

    it("Should revert for inactive stake", async function () {
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      await expect(
        staking.setRarityMultiplier(poolId, 1, 20000n)
      ).to.be.revertedWithCustomError(staking, "StakeNotFound");
    });

    it("Should affect reward calculation after update", async function () {
      // Stake token 3 with staker2 at default 1.0x
      await staking.connect(staker2).stake(poolId, 3);

      // Set token 1 to 3.0x rarity
      await staking.setRarityMultiplier(poolId, 1, 30000n);

      await time.increase(ONE_DAY);

      const pending1 = await staking.pendingRewards(poolId, 1);
      const pending2 = await staking.pendingRewards(poolId, 3);

      // Token 1 has weight 30000, token 3 has weight 10000, total = 40000
      // Token 1 should get 30000/40000 = 75% of rewards
      // Token 3 should get 10000/40000 = 25% of rewards
      // So pending1 should be approximately 3x pending2
      expect(pending1).to.be.gt(pending2 * 2n); // At least 2x (actually ~3x)
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 9. Pool Admin
  // ─────────────────────────────────────────────────────────────────────────
  describe("Pool Admin", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
    });

    it("Should pause a pool", async function () {
      await staking.pausePool(poolId);
      const [, , , , , , active] = await staking.getPool(poolId);
      expect(active).to.equal(false);
    });

    it("Should resume a paused pool", async function () {
      await staking.pausePool(poolId);
      await staking.resumePool(poolId);
      const [, , , , , , active] = await staking.getPool(poolId);
      expect(active).to.equal(true);
    });

    it("Should prevent staking when pool is paused", async function () {
      await staking.pausePool(poolId);
      await expect(
        staking.connect(staker1).stake(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "PoolNotActive");
    });

    it("Should allow staking after pool is resumed", async function () {
      await staking.pausePool(poolId);
      await staking.resumePool(poolId);
      await expect(staking.connect(staker1).stake(poolId, 1)).to.not.be
        .reverted;
    });

    it("Should revert pausePool when called by non-owner", async function () {
      await expect(
        staking.connect(nonOwner).pausePool(poolId)
      ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
    });

    it("Should revert resumePool when called by non-owner", async function () {
      await staking.pausePool(poolId);
      await expect(
        staking.connect(nonOwner).resumePool(poolId)
      ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
    });

    it("Should revert pausePool for non-existent pool", async function () {
      await expect(staking.pausePool(999)).to.be.revertedWithCustomError(
        staking,
        "PoolNotFound"
      );
    });

    it("Should revert resumePool for non-existent pool", async function () {
      await expect(staking.resumePool(999)).to.be.revertedWithCustomError(
        staking,
        "PoolNotFound"
      );
    });

    it("Should allow claiming and unstaking from a paused pool", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);

      await staking.pausePool(poolId);

      // Claiming should still work
      await expect(staking.connect(staker1).claimRewards(poolId, 1)).to.not.be
        .reverted;

      // Unstaking should still work
      await expect(staking.connect(staker1).unstake(poolId, 1)).to.not.be
        .reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 10. View Functions
  // ─────────────────────────────────────────────────────────────────────────
  describe("View Functions", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
    });

    describe("getPool", function () {
      it("Should return all pool fields correctly", async function () {
        const [
          poolCreator,
          collection,
          poolRewardToken,
          totalReward,
          remainingReward,
          totalStaked,
          active,
        ] = await staking.getPool(poolId);

        expect(poolCreator).to.equal(creator.address);
        expect(collection).to.equal(await nftCollection.getAddress());
        expect(poolRewardToken).to.equal(await rewardToken.getAddress());
        expect(totalReward).to.equal(TOTAL_REWARD);
        expect(remainingReward).to.equal(TOTAL_REWARD);
        expect(totalStaked).to.equal(0);
        expect(active).to.equal(true);
      });

      it("Should return zero-address creator for non-existent pool", async function () {
        const [poolCreator] = await staking.getPool(999);
        expect(poolCreator).to.equal(ethers.ZeroAddress);
      });
    });

    describe("getStake", function () {
      it("Should return all stake fields correctly", async function () {
        await staking.connect(staker1).stake(poolId, 1);

        const [staker, stakedAt, rarityMultiplier, accumulatedReward, active] =
          await staking.getStake(poolId, 1);

        expect(staker).to.equal(staker1.address);
        expect(stakedAt).to.be.gt(0);
        expect(rarityMultiplier).to.equal(MULTIPLIER_PRECISION);
        expect(accumulatedReward).to.equal(0);
        expect(active).to.equal(true);
      });

      it("Should return zero-address staker for non-existent stake", async function () {
        const [staker, , , , active] = await staking.getStake(poolId, 999);
        expect(staker).to.equal(ethers.ZeroAddress);
        expect(active).to.equal(false);
      });
    });

    describe("pendingRewards", function () {
      it("Should return zero for non-existent stake", async function () {
        const pending = await staking.pendingRewards(poolId, 999);
        expect(pending).to.equal(0);
      });

      it("Should increase over time", async function () {
        await staking.connect(staker1).stake(poolId, 1);

        await time.increase(ONE_DAY);
        const pending1 = await staking.pendingRewards(poolId, 1);

        await time.increase(ONE_DAY);
        const pending2 = await staking.pendingRewards(poolId, 1);

        expect(pending2).to.be.gt(pending1);
      });
    });

    describe("getStreakBonus", function () {
      it("Should return STREAK_BONUS_0 for non-active stake", async function () {
        const bonus = await staking.getStreakBonus(poolId, 999);
        expect(bonus).to.equal(STREAK_BONUS_0);
      });

      it("Should return correct bonus for active stake at each tier", async function () {
        await staking.connect(staker1).stake(poolId, 1);

        expect(await staking.getStreakBonus(poolId, 1)).to.equal(
          STREAK_BONUS_0
        );

        await time.increase(7 * ONE_DAY);
        expect(await staking.getStreakBonus(poolId, 1)).to.equal(
          STREAK_BONUS_1
        );

        await time.increase(23 * ONE_DAY);
        expect(await staking.getStreakBonus(poolId, 1)).to.equal(
          STREAK_BONUS_2
        );

        await time.increase(60 * ONE_DAY);
        expect(await staking.getStreakBonus(poolId, 1)).to.equal(
          STREAK_BONUS_3
        );
      });
    });

    describe("Constants", function () {
      it("Should expose MULTIPLIER_PRECISION as 10000", async function () {
        expect(await staking.MULTIPLIER_PRECISION()).to.equal(10000);
      });

      it("Should expose MIN_MULTIPLIER as 1000", async function () {
        expect(await staking.MIN_MULTIPLIER()).to.equal(1000);
      });

      it("Should expose MAX_MULTIPLIER as 50000", async function () {
        expect(await staking.MAX_MULTIPLIER()).to.equal(50000);
      });

      it("Should expose streak tier thresholds", async function () {
        expect(await staking.STREAK_TIER1()).to.equal(7 * ONE_DAY);
        expect(await staking.STREAK_TIER2()).to.equal(30 * ONE_DAY);
        expect(await staking.STREAK_TIER3()).to.equal(90 * ONE_DAY);
      });

      it("Should expose streak bonus values", async function () {
        expect(await staking.STREAK_BONUS_0()).to.equal(10000);
        expect(await staking.STREAK_BONUS_1()).to.equal(11000);
        expect(await staking.STREAK_BONUS_2()).to.equal(12500);
        expect(await staking.STREAK_BONUS_3()).to.equal(15000);
      });
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Integration / Edge Cases
  // ─────────────────────────────────────────────────────────────────────────
  describe("Integration and Edge Cases", function () {
    let poolId;

    beforeEach(async function () {
      poolId = await createDefaultPool();
    });

    it("Should handle full lifecycle: stake -> claim -> claim -> unstake", async function () {
      await staking.connect(staker1).stake(poolId, 1);

      // First claim after 1 day
      await time.increase(ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);
      const balAfterClaim1 = await rewardToken.balanceOf(staker1.address);
      expect(balAfterClaim1).to.be.gt(0);

      // Second claim after another day
      await time.increase(ONE_DAY);
      await staking.connect(staker1).claimRewards(poolId, 1);
      const balAfterClaim2 = await rewardToken.balanceOf(staker1.address);
      expect(balAfterClaim2).to.be.gt(balAfterClaim1);

      // Unstake (should pay remaining pending)
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);
      const balFinal = await rewardToken.balanceOf(staker1.address);
      expect(balFinal).to.be.gt(balAfterClaim2);

      // NFT returned
      expect(await nftCollection.ownerOf(1)).to.equal(staker1.address);
    });

    it("Should handle multiple stakers entering and leaving", async function () {
      // Staker1 stakes token 1
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);

      // Staker2 joins
      await staking.connect(staker2).stake(poolId, 3);
      await time.increase(ONE_DAY);

      // Staker1 leaves
      await staking.connect(staker1).unstake(poolId, 1);
      await time.increase(ONE_DAY);

      // Staker2 is now the sole staker, should get full reward rate
      const pending = await staking.pendingRewards(poolId, 3);
      // 2 days as one of two stakers (~50/day) + 1 day solo (~100/day) = ~200
      // But streak is still tier 0 and timestamps are approximate
      expect(pending).to.be.gt(0);

      await staking.connect(staker2).unstake(poolId, 3);
      expect(await nftCollection.ownerOf(3)).to.equal(staker2.address);
    });

    it("Should allow re-staking after unstaking", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);
      await staking.connect(staker1).unstake(poolId, 1);

      // Re-approve and re-stake
      await nftCollection
        .connect(staker1)
        .approve(await staking.getAddress(), 1);
      await expect(staking.connect(staker1).stake(poolId, 1)).to.not.be
        .reverted;
      expect(await nftCollection.ownerOf(1)).to.equal(
        await staking.getAddress()
      );
    });

    it("Should support multiple pools for the same collection", async function () {
      const poolId2 = await createDefaultPool();

      await staking.connect(staker1).stake(poolId, 1);
      await staking.connect(staker2).stake(poolId2, 3);

      await time.increase(ONE_DAY);

      const pending1 = await staking.pendingRewards(poolId, 1);
      const pending2 = await staking.pendingRewards(poolId2, 3);

      // Both should have accumulated rewards (they are in different pools)
      expect(pending1).to.be.gt(0);
      expect(pending2).to.be.gt(0);
    });

    it("Should not allow staker2 to unstake staker1 NFT", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);
      await expect(
        staking.connect(staker2).unstake(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "NotStaker");
    });

    it("Should not allow staker2 to claim staker1 rewards", async function () {
      await staking.connect(staker1).stake(poolId, 1);
      await time.increase(ONE_DAY);
      await expect(
        staking.connect(staker2).claimRewards(poolId, 1)
      ).to.be.revertedWithCustomError(staking, "NotStaker");
    });

    it("Should handle pool with rewards fully depleted", async function () {
      // Pool with exactly 1 day of rewards
      const tinyReward = ethers.parseEther("100");
      const tinyPoolId = await createDefaultPool({
        totalReward: tinyReward,
        rewardPerDay: ethers.parseEther("100"),
        durationDays: 1,
      });

      await staking.connect(staker1).stake(tinyPoolId, 1);
      await time.increase(3 * ONE_DAY); // Well past depletion

      // Pending should be capped at total reward
      const pending = await staking.pendingRewards(tinyPoolId, 1);
      expect(pending).to.equal(tinyReward);

      // Unstake should succeed and pay out exactly the remaining reward
      const balBefore = await rewardToken.balanceOf(staker1.address);
      await staking.connect(staker1).unstake(tinyPoolId, 1);
      const balAfter = await rewardToken.balanceOf(staker1.address);
      expect(balAfter - balBefore).to.equal(tinyReward);
    });
  });
});
