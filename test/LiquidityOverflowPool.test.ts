/**
 * @file LiquidityOverflowPool.test.ts
 * @description Tests for LiquidityOverflowPool contract
 *
 * Tests cover:
 * - Initialization
 * - Pool management (add, weight, vesting params, active toggle)
 * - Overflow distribution (push-based from reward source)
 * - Staking and unstaking LP tokens
 * - Reward claiming (immediate + vested)
 * - Emergency withdrawal
 * - Anti-flash-stake (MIN_STAKE_DURATION)
 * - Vesting mechanics (30/70 split, 90-day period)
 * - Access control
 * - Edge cases
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('LiquidityOverflowPool', function () {
    let overflowPool: any;
    let xomToken: any;
    let lpToken1: any;
    let lpToken2: any;

    let owner: any;
    let rewardSource: any;
    let staker1: any;
    let staker2: any;
    let treasury: any;
    let unauthorized: any;

    const _BPS = 10000;
    const _DEFAULT_IMMEDIATE_BPS = 3000; // 30%
    const _DEFAULT_VESTING = 90 * 24 * 60 * 60; // 90 days
    const MIN_STAKE = 24 * 60 * 60; // 1 day

    beforeEach(async function () {
        [owner, rewardSource, staker1, staker2, treasury, unauthorized] =
            await ethers.getSigners();

        // Deploy mock tokens
        const MockToken = await ethers.getContractFactory('MockXOMToken');
        xomToken = await MockToken.deploy();
        lpToken1 = await MockToken.deploy();
        lpToken2 = await MockToken.deploy();

        // Deploy LiquidityOverflowPool as UUPS proxy
        const LiquidityOverflowPool = await ethers.getContractFactory('LiquidityOverflowPool');
        overflowPool = await upgrades.deployProxy(
            LiquidityOverflowPool,
            [await xomToken.getAddress(), treasury.address],
            { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
        );
        await overflowPool.waitForDeployment();

        // Authorize reward source
        await overflowPool.setRewardSource(rewardSource.address, true);

        // Mint tokens
        await xomToken.mint(rewardSource.address, ethers.parseEther('1000000'));
        await lpToken1.mint(staker1.address, ethers.parseEther('10000'));
        await lpToken1.mint(staker2.address, ethers.parseEther('10000'));
        await lpToken2.mint(staker1.address, ethers.parseEther('10000'));

        // Approve overflow pool for reward source
        await xomToken
            .connect(rewardSource)
            .approve(await overflowPool.getAddress(), ethers.MaxUint256);

        // Approve LP tokens for stakers
        await lpToken1
            .connect(staker1)
            .approve(await overflowPool.getAddress(), ethers.MaxUint256);
        await lpToken1
            .connect(staker2)
            .approve(await overflowPool.getAddress(), ethers.MaxUint256);
        await lpToken2
            .connect(staker1)
            .approve(await overflowPool.getAddress(), ethers.MaxUint256);
    });

    // ================================================================
    //  INITIALIZATION
    // ================================================================

    describe('Initialization', function () {
        it('should initialize with correct XOM token', async function () {
            expect(await overflowPool.xomToken()).to.equal(await xomToken.getAddress());
        });

        it('should initialize with correct treasury', async function () {
            expect(await overflowPool.protocolTreasury()).to.equal(treasury.address);
        });

        it('should grant admin role to deployer', async function () {
            const adminRole = await overflowPool.DEFAULT_ADMIN_ROLE();
            expect(await overflowPool.hasRole(adminRole, owner.address)).to.be.true;
        });

        it('should reject zero XOM address', async function () {
            const LiquidityOverflowPool = await ethers.getContractFactory('LiquidityOverflowPool');
            await expect(
                upgrades.deployProxy(
                    LiquidityOverflowPool,
                    [ethers.ZeroAddress, treasury.address],
                    { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
                )
            ).to.be.revertedWithCustomError(LiquidityOverflowPool, 'ZeroAddress');
        });

        it('should reject zero treasury address', async function () {
            const LiquidityOverflowPool = await ethers.getContractFactory('LiquidityOverflowPool');
            await expect(
                upgrades.deployProxy(
                    LiquidityOverflowPool,
                    [await xomToken.getAddress(), ethers.ZeroAddress],
                    { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
                )
            ).to.be.revertedWithCustomError(LiquidityOverflowPool, 'ZeroAddress');
        });
    });

    // ================================================================
    //  POOL MANAGEMENT
    // ================================================================

    describe('Pool Management', function () {
        it('should add a pool with correct params', async function () {
            await expect(
                overflowPool.addPool(await lpToken1.getAddress(), 10000)
            ).to.emit(overflowPool, 'PoolAdded')
                .withArgs(0, await lpToken1.getAddress(), 10000);

            expect(await overflowPool.poolCount()).to.equal(1);
            expect(await overflowPool.totalWeightBps()).to.equal(10000);
        });

        it('should add multiple pools with weights summing to 10000', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 6000);
            await overflowPool.addPool(await lpToken2.getAddress(), 4000);

            expect(await overflowPool.poolCount()).to.equal(2);
            expect(await overflowPool.totalWeightBps()).to.equal(10000);
        });

        it('should reject weight exceeding BPS_DENOMINATOR', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 7000);
            await expect(
                overflowPool.addPool(await lpToken2.getAddress(), 4000)
            ).to.be.revertedWithCustomError(overflowPool, 'WeightTooHigh');
        });

        it('should reject duplicate LP token', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 5000);
            await expect(
                overflowPool.addPool(await lpToken1.getAddress(), 3000)
            ).to.be.revertedWithCustomError(overflowPool, 'DuplicateLpToken');
        });

        it('should reject zero address LP token', async function () {
            await expect(
                overflowPool.addPool(ethers.ZeroAddress, 5000)
            ).to.be.revertedWithCustomError(overflowPool, 'ZeroAddress');
        });

        it('should update pool weight', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);

            await expect(overflowPool.setPoolWeight(0, 6000))
                .to.emit(overflowPool, 'PoolWeightUpdated')
                .withArgs(0, 10000, 6000);

            expect(await overflowPool.totalWeightBps()).to.equal(6000);
        });

        it('should set vesting params', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
            await overflowPool.setVestingParams(0, 5000, 30 * 24 * 60 * 60);

            const pool = await overflowPool.getPoolInfo(0);
            expect(pool.immediateBps).to.equal(5000);
            expect(pool.vestingPeriod).to.equal(30 * 24 * 60 * 60);
        });

        it('should reject vesting period too short', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
            await expect(
                overflowPool.setVestingParams(0, 3000, 100) // 100 seconds < 1 day
            ).to.be.revertedWithCustomError(overflowPool, 'VestingTooShort');
        });

        it('should toggle pool active status', async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
            await overflowPool.setPoolActive(0, false);

            const pool = await overflowPool.getPoolInfo(0);
            expect(pool.active).to.equal(false);
        });

        it('should reject non-manager pool operations', async function () {
            await expect(
                overflowPool.connect(unauthorized).addPool(await lpToken1.getAddress(), 10000)
            ).to.be.reverted;
        });
    });

    // ================================================================
    //  OVERFLOW DISTRIBUTION
    // ================================================================

    describe('Overflow Distribution', function () {
        beforeEach(async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
        });

        it('should accept overflow from authorized source', async function () {
            // Staker stakes LP tokens first
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));

            // Wait for MIN_STAKE_DURATION
            await time.increase(MIN_STAKE + 1);

            const amount = ethers.parseEther('10');
            await expect(
                overflowPool.connect(rewardSource).distributeOverflow(amount)
            ).to.emit(overflowPool, 'OverflowDistributed');

            expect(await overflowPool.totalOverflowReceived()).to.equal(amount);
        });

        it('should reject overflow from unauthorized source', async function () {
            await expect(
                overflowPool.connect(unauthorized).distributeOverflow(ethers.parseEther('10'))
            ).to.be.revertedWithCustomError(overflowPool, 'NotRewardSource');
        });

        it('should reject zero amount', async function () {
            await expect(
                overflowPool.connect(rewardSource).distributeOverflow(0)
            ).to.be.revertedWithCustomError(overflowPool, 'ZeroAmount');
        });

        it('should distribute overflow proportionally to pools', async function () {
            // Add second pool
            // First reduce pool 1 weight
            await overflowPool.setPoolWeight(0, 6000);
            await overflowPool.addPool(await lpToken2.getAddress(), 4000);

            // Stake in both pools
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));
            await overflowPool.connect(staker1).stake(1, ethers.parseEther('100'));

            await time.increase(MIN_STAKE + 1);

            // Distribute overflow
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            // Check pool accRewardPerShare updated
            const pool0 = await overflowPool.getPoolInfo(0);
            const pool1 = await overflowPool.getPoolInfo(1);

            // Pool 0 (60% weight) should have higher accRewardPerShare
            expect(pool0.accRewardPerShare).to.be.gt(pool1.accRewardPerShare);
        });

        it('should revert when no pools have stakers', async function () {
            // No stakers — pool has 0 totalStaked, should revert to avoid absorbing tokens
            await expect(
                overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('10'))
            ).to.be.revertedWithCustomError(overflowPool, 'NoActiveStakers');
        });
    });

    // ================================================================
    //  STAKING / UNSTAKING
    // ================================================================

    describe('Staking and Unstaking', function () {
        beforeEach(async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
        });

        it('should allow staking LP tokens', async function () {
            const amount = ethers.parseEther('100');
            await expect(overflowPool.connect(staker1).stake(0, amount))
                .to.emit(overflowPool, 'Staked')
                .withArgs(staker1.address, 0, amount);

            const userStake = await overflowPool.getUserStake(0, staker1.address);
            expect(userStake.amount).to.equal(amount);
        });

        it('should reject staking zero amount', async function () {
            await expect(
                overflowPool.connect(staker1).stake(0, 0)
            ).to.be.revertedWithCustomError(overflowPool, 'ZeroAmount');
        });

        it('should reject staking in invalid pool', async function () {
            await expect(
                overflowPool.connect(staker1).stake(99, ethers.parseEther('100'))
            ).to.be.revertedWithCustomError(overflowPool, 'InvalidPool');
        });

        it('should reject staking in inactive pool', async function () {
            await overflowPool.setPoolActive(0, false);
            await expect(
                overflowPool.connect(staker1).stake(0, ethers.parseEther('100'))
            ).to.be.revertedWithCustomError(overflowPool, 'PoolNotActive');
        });

        it('should allow unstaking after MIN_STAKE_DURATION', async function () {
            const amount = ethers.parseEther('100');
            await overflowPool.connect(staker1).stake(0, amount);

            await time.increase(MIN_STAKE + 1);

            await expect(overflowPool.connect(staker1).unstake(0, amount))
                .to.emit(overflowPool, 'Unstaked')
                .withArgs(staker1.address, 0, amount);
        });

        it('should reject unstaking before MIN_STAKE_DURATION', async function () {
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));

            // Try to unstake immediately
            await expect(
                overflowPool.connect(staker1).unstake(0, ethers.parseEther('100'))
            ).to.be.revertedWithCustomError(overflowPool, 'StakeTooRecent');
        });

        it('should reject unstaking more than staked', async function () {
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));
            await time.increase(MIN_STAKE + 1);

            await expect(
                overflowPool.connect(staker1).unstake(0, ethers.parseEther('200'))
            ).to.be.revertedWithCustomError(overflowPool, 'InsufficientBalance');
        });
    });

    // ================================================================
    //  REWARD CLAIMING
    // ================================================================

    describe('Reward Claiming', function () {
        beforeEach(async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));
            await time.increase(MIN_STAKE + 1);
        });

        it('should distribute and claim immediate rewards', async function () {
            // Push overflow
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            // Check pending rewards
            const [immediate, ,] = await overflowPool.pendingRewards(0, staker1.address);
            expect(immediate).to.be.gt(0);

            // Claim
            const balBefore = await xomToken.balanceOf(staker1.address);
            await overflowPool.connect(staker1).claimRewards(0);
            const balAfter = await xomToken.balanceOf(staker1.address);

            expect(balAfter - balBefore).to.be.gt(0);
        });

        it('should apply 30/70 split for immediate vs vesting', async function () {
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            // Harvest via claimRewards to see the split
            const [immediate, , vestingRemaining] =
                await overflowPool.pendingRewards(0, staker1.address);

            // 30% immediate, 70% vesting
            // Total should be approximately 100 XOM (only staker)
            const total = immediate + vestingRemaining;
            expect(immediate).to.be.closeTo(
                (total * BigInt(3000)) / BigInt(10000),
                ethers.parseEther('1')
            );
        });

        it('should vest rewards linearly over 90 days', async function () {
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            // Claim immediate first
            await overflowPool.connect(staker1).claimRewards(0);

            // Advance 45 days (half vesting period)
            await time.increase(45 * 24 * 60 * 60);

            const [, vested, remaining] =
                await overflowPool.pendingRewards(0, staker1.address);

            // About half should be vested at 45 days
            if (vested + remaining > BigInt(0)) {
                const ratio = (vested * BigInt(100)) / (vested + remaining);
                expect(ratio).to.be.closeTo(BigInt(50), BigInt(5)); // ~50%
            }
        });

        it('should fully vest after 90 days', async function () {
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            // Claim immediate
            await overflowPool.connect(staker1).claimRewards(0);

            // Advance past vesting period
            await time.increase(91 * 24 * 60 * 60);

            const [, vested, remaining] =
                await overflowPool.pendingRewards(0, staker1.address);

            expect(remaining).to.equal(0);
            expect(vested).to.be.gt(0);
        });

        it('should reject claim when no rewards', async function () {
            await expect(
                overflowPool.connect(staker2).claimRewards(0)
            ).to.be.revertedWithCustomError(overflowPool, 'NoRewardsToClaim');
        });

        it('should distribute proportionally to multiple stakers', async function () {
            // Staker 2 stakes 3x as much
            await overflowPool.connect(staker2).stake(0, ethers.parseEther('300'));
            await time.increase(MIN_STAKE + 1);

            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            const [imm1, ,] = await overflowPool.pendingRewards(0, staker1.address);
            const [imm2, ,] = await overflowPool.pendingRewards(0, staker2.address);

            // Staker 2 should get ~3x staker 1's rewards
            // Staker 1: 100/(100+300) = 25%
            // Staker 2: 300/(100+300) = 75%
            // Both must actually accrue an immediate reward (immediateBps
            // defaults to 3000), otherwise the ratio check below is vacuous.
            expect(imm1).to.be.gt(BigInt(0));
            expect(imm2).to.be.gt(BigInt(0));
            const ratio = (imm2 * BigInt(100)) / imm1;
            expect(ratio).to.be.closeTo(BigInt(300), BigInt(20)); // ~3x
        });
    });

    // ================================================================
    //  EMERGENCY WITHDRAWAL
    // ================================================================

    describe('Emergency Withdrawal', function () {
        beforeEach(async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));
        });

        it('should allow emergency withdrawal', async function () {
            await expect(overflowPool.connect(staker1).emergencyWithdraw(0))
                .to.emit(overflowPool, 'EmergencyWithdrawal');
        });

        it('should apply 0.5% fee on emergency withdrawal', async function () {
            const staked = ethers.parseEther('100');
            const expectedFee = (staked * BigInt(50)) / BigInt(10000); // 0.5%
            const expectedReturn = staked - expectedFee;

            const balBefore = await lpToken1.balanceOf(staker1.address);
            await overflowPool.connect(staker1).emergencyWithdraw(0);
            const balAfter = await lpToken1.balanceOf(staker1.address);

            expect(balAfter - balBefore).to.equal(expectedReturn);
        });

        it('should send fee to protocol treasury', async function () {
            const staked = ethers.parseEther('100');
            const expectedFee = (staked * BigInt(50)) / BigInt(10000);

            const treasuryBefore = await lpToken1.balanceOf(treasury.address);
            await overflowPool.connect(staker1).emergencyWithdraw(0);
            const treasuryAfter = await lpToken1.balanceOf(treasury.address);

            expect(treasuryAfter - treasuryBefore).to.equal(expectedFee);
        });

        it('should clear all user state on emergency withdrawal', async function () {
            // Push some rewards first
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('10'));

            await overflowPool.connect(staker1).emergencyWithdraw(0);

            const userStake = await overflowPool.getUserStake(0, staker1.address);
            expect(userStake.amount).to.equal(0);
            expect(userStake.rewardDebt).to.equal(0);
            expect(userStake.pendingImmediate).to.equal(0);
            expect(userStake.vestingTotal).to.equal(0);
        });

        it('should work even when paused', async function () {
            await overflowPool.pause();

            // Emergency withdraw should still work
            await expect(
                overflowPool.connect(staker1).emergencyWithdraw(0)
            ).to.not.be.reverted;
        });

        it('should reject emergency withdrawal with zero stake', async function () {
            await expect(
                overflowPool.connect(staker2).emergencyWithdraw(0)
            ).to.be.revertedWithCustomError(overflowPool, 'ZeroAmount');
        });

        it('captures no reward via claim-then-emergency-withdraw within MIN_STAKE (anti-flash-stake)', async function () {
            // A flash-staker deposits (beforeEach staked 100), a distribution
            // lands, and they try to skim the immediate slice and exit inside
            // MIN_STAKE_DURATION. claimRewards must be locked, and
            // emergencyWithdraw must forfeit the reward — so the net XOM
            // captured is 0, never more than the 0.5% emergency fee.
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('100'));

            // While still staked and inside MIN_STAKE, the immediate slice is
            // NOT harvestable.
            await expect(
                overflowPool.connect(staker1).claimRewards(0)
            ).to.be.revertedWithCustomError(overflowPool, 'StakeTooRecent');

            // Emergency-exit within MIN_STAKE forfeits all accrued rewards.
            const xomBefore = await xomToken.balanceOf(staker1.address);
            await overflowPool.connect(staker1).emergencyWithdraw(0);
            const xomAfter = await xomToken.balanceOf(staker1.address);

            // Zero XOM reward captured — strictly less than any positive fee.
            expect(xomAfter - xomBefore).to.equal(0n);

            // The forfeited rewards cannot be reclaimed afterward either.
            await expect(
                overflowPool.connect(staker1).claimRewards(0)
            ).to.be.revertedWithCustomError(overflowPool, 'NoRewardsToClaim');
        });
    });

    // ================================================================
    //  PAUSE
    // ================================================================

    describe('Pause', function () {
        beforeEach(async function () {
            await overflowPool.addPool(await lpToken1.getAddress(), 10000);
        });

        it('should block staking when paused', async function () {
            await overflowPool.pause();
            await expect(
                overflowPool.connect(staker1).stake(0, ethers.parseEther('100'))
            ).to.be.reverted;
        });

        it('should block overflow distribution when paused', async function () {
            await overflowPool.pause();
            await expect(
                overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('10'))
            ).to.be.reverted;
        });

        it('should allow claiming when paused', async function () {
            await overflowPool.connect(staker1).stake(0, ethers.parseEther('100'));
            await time.increase(MIN_STAKE + 1);
            await overflowPool.connect(rewardSource).distributeOverflow(ethers.parseEther('10'));

            await overflowPool.pause();

            // Claim should still work
            await expect(
                overflowPool.connect(staker1).claimRewards(0)
            ).to.not.be.reverted;
        });
    });

    // ================================================================
    //  REWARD SOURCE MANAGEMENT
    // ================================================================

    describe('Reward Source Management', function () {
        it('should add reward source', async function () {
            const newSource = staker1.address;
            await expect(overflowPool.setRewardSource(newSource, true))
                .to.emit(overflowPool, 'RewardSourceUpdated')
                .withArgs(newSource, true);

            expect(await overflowPool.rewardSources(newSource)).to.be.true;
        });

        it('should remove reward source', async function () {
            await overflowPool.setRewardSource(rewardSource.address, false);
            expect(await overflowPool.rewardSources(rewardSource.address)).to.be.false;
        });

        it('should reject non-admin setting reward source', async function () {
            await expect(
                overflowPool.connect(unauthorized).setRewardSource(staker1.address, true)
            ).to.be.reverted;
        });
    });
});
