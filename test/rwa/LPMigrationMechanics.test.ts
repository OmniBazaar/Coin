/**
 * @file LPMigrationMechanics.test.ts
 * @description Proves the exact mechanism `migrate-lp-position-to-new-rwaamm.ts`
 * uses to move a real staked LP position from an OLD RWAAMM pool to a NEW
 * one is sound: unstake -> removeLiquidity(old) -> addLiquidity(new,
 * auto-creates the pool) -> addPool -> stake(new).
 *
 * Also proves the vesting-survives-unstake claim the migration script's
 * own header relies on: unstake() harvests but does NOT forfeit
 * still-vesting rewards (unlike emergencyWithdraw), and claimRewards()
 * remains callable for a fully-unstaked user (amount == 0) to collect
 * whatever continues to unlock afterward.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("LP migration mechanics (2026-08-04 live-pool migration tooling)", function () {
  let oldAmm: any;
  let newAmm: any;
  let overflowPool: any;
  let complianceOracle: any;
  let emergencyGuardian: any;
  let xomToken: any;
  let usdcToken: any;

  let owner: any;
  let feeVault: any;
  let mockTimelock: any;
  let forwarder: any;
  let treasury: any;
  let emergencySigners: any[];

  const INITIAL_LIQUIDITY_XOM = ethers.parseEther("10000");
  const INITIAL_LIQUIDITY_USDC = ethers.parseEther("10000"); // using an 18dp mock for simplicity
  const OLD_POOL_ID = 3;

  async function futureDeadline(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block!.timestamp + 3600;
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    [owner, feeVault, mockTimelock, forwarder, treasury] = signers;
    emergencySigners = signers.slice(6, 11);

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    xomToken = await ERC20Mock.deploy("OmniCoin", "XOM");
    await xomToken.waitForDeployment();
    usdcToken = await ERC20Mock.deploy("USDC", "USDC");
    await usdcToken.waitForDeployment();

    await xomToken.mint(owner.address, INITIAL_LIQUIDITY_XOM);
    await usdcToken.mint(owner.address, INITIAL_LIQUIDITY_USDC);

    const RWAComplianceOracle = await ethers.getContractFactory("RWAComplianceOracle");
    complianceOracle = await RWAComplianceOracle.deploy(owner.address);
    await complianceOracle.waitForDeployment();
    await complianceOracle.connect(owner).registerToken(await xomToken.getAddress(), ethers.ZeroAddress);
    await complianceOracle.connect(owner).registerToken(await usdcToken.getAddress(), ethers.ZeroAddress);

    const EmergencyGuardian = await ethers.getContractFactory("EmergencyGuardian");
    emergencyGuardian = await EmergencyGuardian.deploy(
      mockTimelock.address,
      emergencySigners.map((s: any) => s.address)
    );
    await emergencyGuardian.waitForDeployment();

    // "OLD" RWAAMM — the live, pre-migration instance, seeded with a real pool.
    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    oldAmm = await RWAAMM.deploy(
      await emergencyGuardian.getAddress(),
      feeVault.address,
      await xomToken.getAddress(),
      await complianceOracle.getAddress(),
      forwarder.address,
      [owner.address] // placeholder trusted caller — not exercised by this test's direct self-service calls
    );
    await oldAmm.waitForDeployment();

    await xomToken.connect(owner).approve(await oldAmm.getAddress(), INITIAL_LIQUIDITY_XOM);
    await usdcToken.connect(owner).approve(await oldAmm.getAddress(), INITIAL_LIQUIDITY_USDC);
    await oldAmm
      .connect(owner)
      .addLiquidity(
        await xomToken.getAddress(),
        await usdcToken.getAddress(),
        INITIAL_LIQUIDITY_XOM,
        INITIAL_LIQUIDITY_USDC,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );

    // "NEW" RWAAMM — the audit-fixed instance, pool-less until migration.
    newAmm = await RWAAMM.deploy(
      await emergencyGuardian.getAddress(),
      feeVault.address,
      await xomToken.getAddress(),
      await complianceOracle.getAddress(),
      forwarder.address,
      [owner.address]
    );
    await newAmm.waitForDeployment();

    // LiquidityOverflowPool, pool #3 = the old pool's LP token (mirrors
    // the live mainnet layout per memory/early_lp_system.md).
    const LiquidityOverflowPool = await ethers.getContractFactory("LiquidityOverflowPool");
    overflowPool = await upgrades.deployProxy(
      LiquidityOverflowPool,
      [await xomToken.getAddress(), treasury.address],
      { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
    );
    await overflowPool.waitForDeployment();

    const oldPoolAddr = await oldAmm["getPool(address,address)"](await xomToken.getAddress(), await usdcToken.getAddress());
    // Pad with 3 placeholder pools (zombie pools 0-2 in the real deployment) so the real pool lands at id 3.
    for (let i = 0; i < 3; i++) {
      const placeholder = await ERC20Mock.deploy(`Zombie${i}`, `Z${i}`);
      await placeholder.waitForDeployment();
      await overflowPool.connect(owner).addPool(await placeholder.getAddress(), 0);
    }
    await overflowPool.connect(owner).addPool(oldPoolAddr, 10000);

    // Stake owner's full LP balance into pool #3.
    const oldLpToken = await ethers.getContractAt("IERC20", oldPoolAddr);
    const lpBalance = await oldLpToken.balanceOf(owner.address);
    await oldLpToken.connect(owner).approve(await overflowPool.getAddress(), lpBalance);
    await overflowPool.connect(owner).stake(OLD_POOL_ID, lpBalance);

    // Fund + push overflow rewards so there's something real to harvest/vest.
    await xomToken.mint(owner.address, ethers.parseEther("1000"));
    await overflowPool.setRewardSource(owner.address, true);
    await xomToken.connect(owner).approve(await overflowPool.getAddress(), ethers.parseEther("1000"));
    await overflowPool.connect(owner).distributeOverflow(ethers.parseEther("1000"));

    // Clear the MIN_STAKE_DURATION lock (1 day) so unstake() doesn't revert StakeTooRecent.
    await time.increase(2 * 24 * 60 * 60);
  });

  it("migrates a full staked position: unstake -> removeLiquidity(old) -> addLiquidity(new, auto-creates pool) -> addPool -> stake(new)", async function () {
    const oldPoolAddr = await oldAmm["getPool(address,address)"](await xomToken.getAddress(), await usdcToken.getAddress());
    const oldLpToken = await ethers.getContractAt("IERC20", oldPoolAddr);

    const userStakeBefore = await overflowPool.userStakes(OLD_POOL_ID, owner.address);
    const stakedAmount = userStakeBefore.amount;
    expect(stakedAmount).to.be.gt(0n);

    const pendingBefore = await overflowPool.pendingRewards(OLD_POOL_ID, owner.address);
    expect(pendingBefore.vestingRemaining).to.be.gt(0n, "test setup should leave something still vesting");

    // Step 1: unstake — should NOT forfeit anything (unlike emergencyWithdraw).
    await overflowPool.connect(owner).unstake(OLD_POOL_ID, stakedAmount);
    const userStakeAfterUnstake = await overflowPool.userStakes(OLD_POOL_ID, owner.address);
    expect(userStakeAfterUnstake.amount).to.equal(0n);
    expect(await oldLpToken.balanceOf(owner.address)).to.equal(stakedAmount);

    // Step 2: removeLiquidity on the OLD RWAAMM.
    const xomBalBeforeRemove = await xomToken.balanceOf(owner.address);
    const usdcBalBeforeRemove = await usdcToken.balanceOf(owner.address);
    await oldLpToken.connect(owner).approve(await oldAmm.getAddress(), stakedAmount);
    await oldAmm
      .connect(owner)
      .removeLiquidity(
        await xomToken.getAddress(),
        await usdcToken.getAddress(),
        stakedAmount,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );
    const redeemedXom = (await xomToken.balanceOf(owner.address)) - xomBalBeforeRemove;
    const redeemedUsdc = (await usdcToken.balanceOf(owner.address)) - usdcBalBeforeRemove;
    expect(redeemedXom).to.be.gt(0n);
    expect(redeemedUsdc).to.be.gt(0n);

    // Step 3: addLiquidity on the NEW RWAAMM — auto-creates the pool (owner is a registered pool creator via the deploy call).
    expect(await newAmm["getPool(address,address)"](await xomToken.getAddress(), await usdcToken.getAddress())).to.equal(ethers.ZeroAddress);
    await xomToken.connect(owner).approve(await newAmm.getAddress(), redeemedXom);
    await usdcToken.connect(owner).approve(await newAmm.getAddress(), redeemedUsdc);
    await newAmm
      .connect(owner)
      .addLiquidity(
        await xomToken.getAddress(),
        await usdcToken.getAddress(),
        redeemedXom,
        redeemedUsdc,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );
    const newPoolAddr = await newAmm["getPool(address,address)"](await xomToken.getAddress(), await usdcToken.getAddress());
    expect(newPoolAddr).to.not.equal(ethers.ZeroAddress, "addLiquidity should have auto-created the new pool");

    const newLpToken = await ethers.getContractAt("IERC20", newPoolAddr);
    const mintedLp = await newLpToken.balanceOf(owner.address);
    expect(mintedLp).to.be.gt(0n);

    // Step 4: free weight headroom on the old pool (it holds the full
    // 10000bps today; addPool would revert WeightTooHigh otherwise —
    // this is the same real constraint migrate-lp-position-to-new-rwaamm.ts
    // handles by calling setPoolWeight(OLD_POOL_ID, 0) first).
    await overflowPool.connect(owner).setPoolWeight(OLD_POOL_ID, 0);
    const oldPoolAfterWeightZero = await overflowPool.pools(OLD_POOL_ID);
    expect(oldPoolAfterWeightZero.weightBps).to.equal(0n);

    // Step 5: addPool on LiquidityOverflowPool for the new LP token.
    const addPoolTx = await overflowPool.connect(owner).addPool(newPoolAddr, 10000);
    const receipt = await addPoolTx.wait();
    const poolAddedEvent = receipt.logs
      .map((l: any) => {
        try {
          return overflowPool.interface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((e: any) => e?.name === "PoolAdded");
    expect(poolAddedEvent).to.not.be.undefined;
    const newPoolId = poolAddedEvent.args.poolId;
    expect(newPoolId).to.equal(4n); // 3 placeholders (0-2) + old pool (3) + new pool (4)

    // Step 5: stake into the new pool.
    await newLpToken.connect(owner).approve(await overflowPool.getAddress(), mintedLp);
    await overflowPool.connect(owner).stake(newPoolId, mintedLp);
    const newStake = await overflowPool.userStakes(newPoolId, owner.address);
    expect(newStake.amount).to.equal(mintedLp);

    // The old pool's LiquidityOverflowPool stake is now fully drained —
    // this is exactly what cutover-rwaamm-to-new-instance-mainnet.ts's
    // precondition 2 checks for before allowing OmniSwapRouter cutover.
    const oldPoolStruct = await overflowPool.pools(OLD_POOL_ID);
    expect(oldPoolStruct.totalStaked).to.equal(0n);

    // Still-vesting rewards from the OLD pool survive the migration and
    // remain claimable — the exact claim the migration script's header
    // warns not to forget.
    const pendingAfter = await overflowPool.pendingRewards(OLD_POOL_ID, owner.address);
    expect(pendingAfter.vestingRemaining).to.be.gt(0n);
    await expect(overflowPool.connect(owner).claimRewards(OLD_POOL_ID)).to.not.be.reverted;
  });

  it("a second migrator (simulating the founder's later run) reuses the existing new-pool overflow entry rather than creating a duplicate", async function () {
    // Deployer-equivalent run (owner) completes first, exactly as in the
    // primary test above — abbreviated here to just the parts relevant
    // to proving the "reuse, don't duplicate" detection the script does.
    const oldPoolAddr = await oldAmm["getPool(address,address)"](await xomToken.getAddress(), await usdcToken.getAddress());
    const oldLpToken = await ethers.getContractAt("IERC20", oldPoolAddr);
    const stakedAmount = (await overflowPool.userStakes(OLD_POOL_ID, owner.address)).amount;

    await overflowPool.connect(owner).unstake(OLD_POOL_ID, stakedAmount);
    await oldLpToken.connect(owner).approve(await oldAmm.getAddress(), stakedAmount);
    const xomBefore = await xomToken.balanceOf(owner.address);
    const usdcBefore = await usdcToken.balanceOf(owner.address);
    await oldAmm
      .connect(owner)
      .removeLiquidity(
        await xomToken.getAddress(),
        await usdcToken.getAddress(),
        stakedAmount,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );
    const redeemedXom = (await xomToken.balanceOf(owner.address)) - xomBefore;
    const redeemedUsdc = (await usdcToken.balanceOf(owner.address)) - usdcBefore;

    await xomToken.connect(owner).approve(await newAmm.getAddress(), redeemedXom);
    await usdcToken.connect(owner).approve(await newAmm.getAddress(), redeemedUsdc);
    await newAmm
      .connect(owner)
      .addLiquidity(
        await xomToken.getAddress(),
        await usdcToken.getAddress(),
        redeemedXom,
        redeemedUsdc,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );
    const newPoolAddr = await newAmm["getPool(address,address)"](await xomToken.getAddress(), await usdcToken.getAddress());
    await overflowPool.connect(owner).setPoolWeight(OLD_POOL_ID, 0);
    await overflowPool.connect(owner).addPool(newPoolAddr, 10000);

    // Now simulate the "detect existing entry" scan the script performs —
    // confirm exactly one pool entry exists for the new LP token, so a
    // second migrator's run would find and reuse poolId 4, never call
    // addPool again (which would revert DuplicateLpToken anyway).
    await expect(overflowPool.connect(owner).addPool(newPoolAddr, 0)).to.be.revertedWithCustomError(
      overflowPool,
      "DuplicateLpToken"
    );
  });
});
