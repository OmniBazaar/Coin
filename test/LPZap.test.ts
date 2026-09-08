/**
 * @file LPZap.test.ts
 * @description Comprehensive tests for the LPZap contract
 *
 * Tests cover:
 * - Constructor validation (immutables, zero address, no pool)
 * - zapIn (swap + addLiquidity + LP transfer, dust return, events, errors)
 * - zapOut (removeLiquidity + swap, USDC return, events, errors)
 * - estimateZapIn (view-only quote estimation)
 * - Reentrancy guard presence
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('LPZap', function () {
    let lpZap: any;
    let mockRWAAMM: any;
    let mockPool: any;
    let xom: any;
    let usdc: any;

    let _owner: any;
    let user1: any;
    let user2: any;
    let overflowPoolAddr: any;

    /**
     * Exchange rate: 1e18 means 1:1 (one unit in = one unit out before fee).
     * We use 1:1 because the mock applies the same rate in both directions
     * (USDC->XOM and XOM->USDC). A non-symmetric rate (e.g. 250) would
     * cause zapOut to require astronomically more USDC than exists. The
     * 1:1 rate still fully exercises all LPZap logic (swap, addLiquidity,
     * removeLiquidity, dust return, slippage, deadlines).
     */
    const EXCHANGE_RATE = ethers.parseEther('1');

    /** Protocol fee in the mock: 30 bps = 0.3% */
    const PROTOCOL_FEE_BPS = 30n;
    const BPS_DENOMINATOR = 10000n;

    /** Initial reserves: 100K of each token (balanced for 1:1 rate) */
    const INITIAL_RESERVE_XOM = ethers.parseEther('100000');
    const INITIAL_RESERVE_USDC = ethers.parseEther('100000');

    /** Initial LP supply minted to pool (so totalSupply > 0 for estimateZapIn) */
    const INITIAL_LP_SUPPLY = ethers.parseEther('100000');

    /** Seed amounts for mock RWAAMM to pay out swaps in both directions */
    const SEED_XOM = ethers.parseEther('10000000');
    const SEED_USDC = ethers.parseEther('10000000');

    /** Standard test amounts */
    const ZAP_AMOUNT = ethers.parseEther('1000'); // 1000 USDC
    const USER_USDC_MINT = ethers.parseEther('50000');

    beforeEach(async function () {
        [_owner, user1, user2] = await ethers.getSigners();

        // Use a deterministic non-zero address for the overflow pool
        // (LPZap doesn't call it in current code, just stores as immutable)
        overflowPoolAddr = ethers.Wallet.createRandom().address;

        // Deploy mock tokens
        const MockToken = await ethers.getContractFactory('MockXOMToken');
        xom = await MockToken.deploy();
        usdc = await MockToken.deploy();

        // Deploy MockRWAAMMForZap with 1:1 exchange rate
        const MockRWAAMM = await ethers.getContractFactory('MockRWAAMMForZap');
        mockRWAAMM = await MockRWAAMM.deploy(EXCHANGE_RATE);

        // Deploy MockRWAPool — token0 must be the lower address
        const xomAddr = await xom.getAddress();
        const usdcAddr = await usdc.getAddress();
        const [token0, token1] = xomAddr.toLowerCase() < usdcAddr.toLowerCase()
            ? [xomAddr, usdcAddr]
            : [usdcAddr, xomAddr];

        // Fully-qualified: a second `MockRWAPool` exists in
        // contracts/test/MockRWAPool.sol, making the bare name ambiguous
        // (HH701). This suite needs the zap-specific mock (has setReserves).
        const MockRWAPool = await ethers.getContractFactory(
          'contracts/mocks/MockRWAAMMForZap.sol:MockRWAPool'
        );
        mockPool = await MockRWAPool.deploy(token0, token1);

        // Register pool in RWAAMM
        await mockRWAAMM.setPool(xomAddr, usdcAddr, await mockPool.getAddress());

        // Seed the mock RWAAMM with tokens so it can pay out swaps
        await xom.mint(await mockRWAAMM.getAddress(), SEED_XOM);
        await usdc.mint(await mockRWAAMM.getAddress(), SEED_USDC);

        // Set initial reserves on pool (order must match token0/token1 sort)
        const [reserve0, reserve1] = xomAddr.toLowerCase() < usdcAddr.toLowerCase()
            ? [INITIAL_RESERVE_XOM, INITIAL_RESERVE_USDC]
            : [INITIAL_RESERVE_USDC, INITIAL_RESERVE_XOM];
        await mockPool.setReserves(reserve0, reserve1);

        // Mint initial LP supply to the pool contract itself (so totalSupply > 0)
        await mockPool.mint(await mockPool.getAddress(), INITIAL_LP_SUPPLY);

        // Also seed the mock RWAAMM with underlying tokens for addLiquidity/removeLiquidity returns
        // (removeLiquidity needs tokens in the RWAAMM to transfer back)
        await xom.mint(await mockRWAAMM.getAddress(), INITIAL_RESERVE_XOM);
        await usdc.mint(await mockRWAAMM.getAddress(), INITIAL_RESERVE_USDC);

        // Deploy LPZap
        const LPZap = await ethers.getContractFactory('LPZap');
        lpZap = await LPZap.deploy(
            await mockRWAAMM.getAddress(),
            xomAddr,
            usdcAddr,
            overflowPoolAddr
        );

        // Mint USDC to user accounts for testing
        await usdc.mint(user1.address, USER_USDC_MINT);
        await usdc.mint(user2.address, USER_USDC_MINT);
    });

    // ================================================================
    //  HELPER: get a future deadline
    // ================================================================

    async function futureDeadline(): Promise<bigint> {
        const latest = await time.latest();
        return BigInt(latest) + 3600n; // 1 hour in the future
    }

    async function pastDeadline(): Promise<bigint> {
        const latest = await time.latest();
        return BigInt(latest) - 1n;
    }

    /**
     * Compute expected swap output for a given input amount.
     * Mirrors the mock's formula: afterFee = amountIn - fee; out = afterFee * rate / 1e18
     */
    function expectedSwapOutput(amountIn: bigint): bigint {
        const fee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        const afterFee = amountIn - fee;
        return (afterFee * EXCHANGE_RATE) / ethers.parseEther('1');
    }

    // ================================================================
    //  CONSTRUCTOR
    // ================================================================

    describe('Constructor', function () {
        it('should deploy with correct immutables', async function () {
            expect(await lpZap.rwaamm()).to.equal(await mockRWAAMM.getAddress());
            expect(await lpZap.xom()).to.equal(await xom.getAddress());
            expect(await lpZap.usdc()).to.equal(await usdc.getAddress());
            expect(await lpZap.overflowPool()).to.equal(overflowPoolAddr);
            expect(await lpZap.lpToken()).to.equal(await mockPool.getAddress());
        });

        it('should store BPS_DENOMINATOR as 10000', async function () {
            expect(await lpZap.BPS_DENOMINATOR()).to.equal(10000n);
        });

        it('should revert on zero address for rwaamm', async function () {
            const LPZap = await ethers.getContractFactory('LPZap');
            await expect(
                LPZap.deploy(
                    ethers.ZeroAddress,
                    await xom.getAddress(),
                    await usdc.getAddress(),
                    overflowPoolAddr
                )
            ).to.be.revertedWithCustomError(LPZap, 'ZeroAddress');
        });

        it('should revert on zero address for xom', async function () {
            const LPZap = await ethers.getContractFactory('LPZap');
            await expect(
                LPZap.deploy(
                    await mockRWAAMM.getAddress(),
                    ethers.ZeroAddress,
                    await usdc.getAddress(),
                    overflowPoolAddr
                )
            ).to.be.revertedWithCustomError(LPZap, 'ZeroAddress');
        });

        it('should revert on zero address for usdc', async function () {
            const LPZap = await ethers.getContractFactory('LPZap');
            await expect(
                LPZap.deploy(
                    await mockRWAAMM.getAddress(),
                    await xom.getAddress(),
                    ethers.ZeroAddress,
                    overflowPoolAddr
                )
            ).to.be.revertedWithCustomError(LPZap, 'ZeroAddress');
        });

        it('should revert on zero address for overflowPool', async function () {
            const LPZap = await ethers.getContractFactory('LPZap');
            await expect(
                LPZap.deploy(
                    await mockRWAAMM.getAddress(),
                    await xom.getAddress(),
                    await usdc.getAddress(),
                    ethers.ZeroAddress
                )
            ).to.be.revertedWithCustomError(LPZap, 'ZeroAddress');
        });

        it('should revert if getPool returns zero (no pool)', async function () {
            // Deploy a fresh mock RWAAMM with no pool registered
            const MockRWAAMM = await ethers.getContractFactory('MockRWAAMMForZap');
            const freshRWAAMM = await MockRWAAMM.deploy(EXCHANGE_RATE);

            const LPZap = await ethers.getContractFactory('LPZap');
            await expect(
                LPZap.deploy(
                    await freshRWAAMM.getAddress(),
                    await xom.getAddress(),
                    await usdc.getAddress(),
                    overflowPoolAddr
                )
            ).to.be.revertedWithCustomError(LPZap, 'NoPoolFound');
        });
    });

    // ================================================================
    //  ZAP IN
    // ================================================================

    describe('zapIn', function () {
        it('should swap half USDC to XOM and create LP tokens', async function () {
            const deadline = await futureDeadline();

            // Approve USDC to LPZap
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            const usdcBefore = await usdc.balanceOf(user1.address);
            const tx = await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);
            await tx.wait();
            const usdcAfter = await usdc.balanceOf(user1.address);

            // User should have spent the zap amount (minus any dust returned)
            expect(usdcBefore - usdcAfter).to.be.lte(ZAP_AMOUNT);

            // User should have received LP tokens
            const lpBalance = await mockPool.balanceOf(user1.address);
            expect(lpBalance).to.be.gt(0n);
        });

        it('should transfer LP tokens to the caller (not keep them)', async function () {
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            // LPZap should hold zero LP tokens
            const zapLPBalance = await mockPool.balanceOf(await lpZap.getAddress());
            expect(zapLPBalance).to.equal(0n);

            // User should hold the LP tokens
            const userLPBalance = await mockPool.balanceOf(user1.address);
            expect(userLPBalance).to.be.gt(0n);
        });

        it('should return dust (leftover XOM/USDC) to caller', async function () {
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            // LPZap contract should hold zero XOM and zero USDC
            const zapXOMBal = await xom.balanceOf(await lpZap.getAddress());
            const zapUSDCBal = await usdc.balanceOf(await lpZap.getAddress());
            expect(zapXOMBal).to.equal(0n);
            expect(zapUSDCBal).to.equal(0n);
        });

        it('should emit ZappedIn event with correct args', async function () {
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            // Calculate expected XOM from swap
            const swapAmount = ZAP_AMOUNT / 2n;
            const expectedXOM = expectedSwapOutput(swapAmount);

            await expect(
                lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline)
            ).to.emit(lpZap, 'ZappedIn')
                .withArgs(
                    user1.address,
                    ZAP_AMOUNT,
                    expectedXOM,
                    // liquidity = (amount0 + amount1) / 2 from mock
                    // amount0 = expectedXOM, amount1 = remainingUSDC = ZAP_AMOUNT - swapAmount
                    (expectedXOM + (ZAP_AMOUNT - swapAmount)) / 2n
                );
        });

        it('should return the correct lpReceived value', async function () {
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            const lpReceived = await lpZap.connect(user1).zapIn.staticCall(
                ZAP_AMOUNT, 0, 0, deadline
            );

            expect(lpReceived).to.be.gt(0n);

            // Verify it matches the actual LP balance after execution
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);
            const lpBalance = await mockPool.balanceOf(user1.address);
            expect(lpBalance).to.equal(lpReceived);
        });

        it('should revert on zero amount', async function () {
            const deadline = await futureDeadline();

            await expect(
                lpZap.connect(user1).zapIn(0, 0, 0, deadline)
            ).to.be.revertedWithCustomError(lpZap, 'ZeroAmount');
        });

        it('should revert on expired deadline', async function () {
            const deadline = await pastDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            await expect(
                lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline)
            ).to.be.revertedWithCustomError(lpZap, 'DeadlineExpired');
        });

        it('should revert on slippage (minLPOut too high)', async function () {
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            // Set minLPOut unreasonably high
            const impossibleMinLP = ethers.parseEther('999999999');

            await expect(
                lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, impossibleMinLP, deadline)
            ).to.be.revertedWithCustomError(lpZap, 'SlippageExceeded');
        });

        it('should revert if user has not approved USDC', async function () {
            const deadline = await futureDeadline();

            // No approval — safeTransferFrom should revert
            await expect(
                lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline)
            ).to.be.reverted;
        });

        it('should emit ZappedIn event with correct params', async function () {
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);

            await expect(
                lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline)
            ).to.emit(lpZap, 'ZappedIn');
        });

        it('should handle small amounts correctly', async function () {
            const deadline = await futureDeadline();
            const smallAmount = ethers.parseEther('2'); // 2 USDC
            await usdc.connect(user1).approve(await lpZap.getAddress(), smallAmount);

            await lpZap.connect(user1).zapIn(smallAmount, 0, 0, deadline);

            const lpBalance = await mockPool.balanceOf(user1.address);
            expect(lpBalance).to.be.gt(0n);
        });

        it('should work for multiple users sequentially', async function () {
            const deadline = await futureDeadline();

            // User 1 zaps in
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            // User 2 zaps in
            await usdc.connect(user2).approve(await lpZap.getAddress(), ZAP_AMOUNT);
            await lpZap.connect(user2).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            // Both should have LP tokens
            const lp1 = await mockPool.balanceOf(user1.address);
            const lp2 = await mockPool.balanceOf(user2.address);
            expect(lp1).to.be.gt(0n);
            expect(lp2).to.be.gt(0n);
        });
    });

    // ================================================================
    //  ZAP OUT
    // ================================================================

    describe('zapOut', function () {
        let userLPBalance: bigint;

        beforeEach(async function () {
            // First zap in so user1 has LP tokens
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);
            userLPBalance = await mockPool.balanceOf(user1.address);
        });

        it('should remove liquidity and swap XOM back to USDC', async function () {
            const deadline = await futureDeadline();

            // Approve LP tokens to LPZap
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            const usdcBefore = await usdc.balanceOf(user1.address);
            await lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline);
            const usdcAfter = await usdc.balanceOf(user1.address);

            // User should have received USDC back
            expect(usdcAfter).to.be.gt(usdcBefore);
        });

        it('should return all USDC to the caller', async function () {
            const deadline = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            await lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline);

            // LPZap should hold zero USDC and zero XOM
            const zapUSDC = await usdc.balanceOf(await lpZap.getAddress());
            const zapXOM = await xom.balanceOf(await lpZap.getAddress());
            expect(zapUSDC).to.equal(0n);
            expect(zapXOM).to.equal(0n);
        });

        it('should burn LP tokens from the user', async function () {
            const deadline = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            await lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline);

            const lpAfter = await mockPool.balanceOf(user1.address);
            expect(lpAfter).to.equal(0n);
        });

        it('should emit ZappedOut event', async function () {
            const deadline = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            await expect(
                lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline)
            ).to.emit(lpZap, 'ZappedOut');
        });

        it('should emit ZappedOut with correct user and lpAmount', async function () {
            const deadline = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            // We check the first two indexed args: user and lpAmount
            const tx = await lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline);
            const receipt = await tx.wait();

            // Find the ZappedOut event
            const zapOutEvent = receipt.logs.find((log: any) => {
                try {
                    const parsed = lpZap.interface.parseLog(log);
                    return parsed && parsed.name === 'ZappedOut';
                } catch {
                    return false;
                }
            });

            expect(zapOutEvent).to.not.be.undefined;
            const parsed = lpZap.interface.parseLog(zapOutEvent);
            expect(parsed.args.user).to.equal(user1.address);
            expect(parsed.args.lpAmount).to.equal(userLPBalance);
            expect(parsed.args.usdcReturned).to.be.gt(0n);
        });

        it('should revert on zero amount', async function () {
            const deadline = await futureDeadline();

            await expect(
                lpZap.connect(user1).zapOut(0, 0, 0, deadline)
            ).to.be.revertedWithCustomError(lpZap, 'ZeroAmount');
        });

        it('should revert on expired deadline', async function () {
            const deadline = await pastDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            await expect(
                lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline)
            ).to.be.revertedWithCustomError(lpZap, 'DeadlineExpired');
        });

        it('should revert on slippage (minUSDCOut too high)', async function () {
            const deadline = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            const impossibleMinUSDC = ethers.parseEther('999999999');

            await expect(
                lpZap.connect(user1).zapOut(userLPBalance, 0, impossibleMinUSDC, deadline)
            ).to.be.revertedWithCustomError(lpZap, 'SlippageExceeded');
        });

        it('should revert if user has not approved LP tokens', async function () {
            const deadline = await futureDeadline();

            // No LP approval — safeTransferFrom should revert
            await expect(
                lpZap.connect(user1).zapOut(userLPBalance, 0, 0, deadline)
            ).to.be.reverted;
        });

        it('should return the correct usdcReturned value', async function () {
            const deadline = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), userLPBalance);

            const usdcReturned = await lpZap.connect(user1).zapOut.staticCall(
                userLPBalance, 0, 0, deadline
            );

            expect(usdcReturned).to.be.gt(0n);
        });

        it('should allow partial zapOut', async function () {
            const deadline = await futureDeadline();
            const halfLP = userLPBalance / 2n;
            await mockPool.connect(user1).approve(await lpZap.getAddress(), halfLP);

            await lpZap.connect(user1).zapOut(halfLP, 0, 0, deadline);

            // User should still hold roughly half LP
            const lpAfter = await mockPool.balanceOf(user1.address);
            expect(lpAfter).to.equal(userLPBalance - halfLP);
        });
    });

    // ================================================================
    //  ESTIMATE ZAP IN
    // ================================================================

    describe('estimateZapIn', function () {
        it('should return non-zero estimates for valid USDC amount', async function () {
            const [xomEstimate, usdcForLP, lpEstimate] =
                await lpZap.estimateZapIn(ZAP_AMOUNT);

            expect(xomEstimate).to.be.gt(0n);
            expect(usdcForLP).to.be.gt(0n);
            expect(lpEstimate).to.be.gt(0n);
        });

        it('should return zeros for zero USDC amount', async function () {
            const [xomEstimate, usdcForLP, lpEstimate] =
                await lpZap.estimateZapIn(0);

            expect(xomEstimate).to.equal(0n);
            expect(usdcForLP).to.equal(0n);
            expect(lpEstimate).to.equal(0n);
        });

        it('xomEstimate should be approximately half the USDC value * exchange rate', async function () {
            const [xomEstimate, ,] = await lpZap.estimateZapIn(ZAP_AMOUNT);

            // Half of ZAP_AMOUNT goes to swap
            const swapAmount = ZAP_AMOUNT / 2n;
            const expectedXOM = expectedSwapOutput(swapAmount);

            expect(xomEstimate).to.equal(expectedXOM);
        });

        it('usdcForLP should be approximately half the input', async function () {
            const [, usdcForLP,] = await lpZap.estimateZapIn(ZAP_AMOUNT);

            // usdcForLP = usdcAmount - swapAmount = usdcAmount - (usdcAmount / 2)
            const expectedUSDCForLP = ZAP_AMOUNT - (ZAP_AMOUNT / 2n);
            expect(usdcForLP).to.equal(expectedUSDCForLP);
        });

        it('lpEstimate should be based on min(xom/rXOM, usdc/rUSDC) * totalSupply', async function () {
            const [xomEstimate, usdcForLP, lpEstimate] =
                await lpZap.estimateZapIn(ZAP_AMOUNT);

            const totalSupply = await mockPool.totalSupply();

            // Read reserves and determine which is XOM / USDC
            const xomAddr = await xom.getAddress();
            const t0 = await mockPool.token0();
            const r0 = await mockPool.reserve0();
            const r1 = await mockPool.reserve1();

            let rXOM: bigint;
            let rUSDC: bigint;
            if (t0.toLowerCase() === xomAddr.toLowerCase()) {
                rXOM = r0;
                rUSDC = r1;
            } else {
                rXOM = r1;
                rUSDC = r0;
            }

            const lpFromXOM = (BigInt(xomEstimate) * totalSupply) / rXOM;
            const lpFromUSDC = (BigInt(usdcForLP) * totalSupply) / rUSDC;
            const expectedLP = lpFromXOM < lpFromUSDC ? lpFromXOM : lpFromUSDC;

            expect(lpEstimate).to.equal(expectedLP);
        });

        it('should handle odd amounts without reverting', async function () {
            const oddAmount = ethers.parseEther('1') + 1n; // 1 USDC + 1 wei
            const [xomEstimate, usdcForLP] =
                await lpZap.estimateZapIn(oddAmount);

            expect(xomEstimate).to.be.gt(0n);
            expect(usdcForLP).to.be.gt(0n);
            // lpEstimate may or may not be > 0 depending on rounding, but should not revert
        });

        it('should handle very large amounts', async function () {
            const largeAmount = ethers.parseEther('1000000'); // 1M USDC
            const [xomEstimate, usdcForLP, lpEstimate] =
                await lpZap.estimateZapIn(largeAmount);

            expect(xomEstimate).to.be.gt(0n);
            expect(usdcForLP).to.be.gt(0n);
            expect(lpEstimate).to.be.gt(0n);
        });
    });

    // ================================================================
    //  REENTRANCY
    // ================================================================

    describe('Reentrancy', function () {
        it('should have nonReentrant modifier on zapIn', async function () {
            // The ReentrancyGuard is inherited. We can verify it works by
            // confirming a normal call succeeds (guard doesn't permanently lock).
            // A full re-entrancy attack test would require a malicious token,
            // but we can at least verify the contract inherits ReentrancyGuard
            // and that sequential calls work (guard resets properly).
            const deadline = await futureDeadline();

            // First zap
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT * 2n);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            // Second zap should also work (guard resets between txs)
            const deadline2 = await futureDeadline();
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline2);

            const lpBalance = await mockPool.balanceOf(user1.address);
            expect(lpBalance).to.be.gt(0n);
        });

        it('should have nonReentrant modifier on zapOut', async function () {
            // Verify sequential zapOut calls work (guard resets)
            const deadline = await futureDeadline();
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT * 2n);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            const totalLP = await mockPool.balanceOf(user1.address);
            const halfLP = totalLP / 2n;

            // Approve LP tokens for both zapOut calls
            await mockPool.connect(user1).approve(await lpZap.getAddress(), totalLP);

            const deadline2 = await futureDeadline();
            await lpZap.connect(user1).zapOut(halfLP, 0, 0, deadline2);

            const deadline3 = await futureDeadline();
            await lpZap.connect(user1).zapOut(halfLP, 0, 0, deadline3);

            // All LP should be gone
            const lpAfter = await mockPool.balanceOf(user1.address);
            expect(lpAfter).to.equal(totalLP - halfLP - halfLP);
        });

        /**
         * Deploy a dedicated LPZap wired to a malicious ReentrantZapToken as
         * its `usdc` token. The token re-enters LPZap from inside its
         * transfer/transferFrom hook; the outer zap's first token movement
         * (usdc.safeTransferFrom in zapIn) triggers the reentrant call, which
         * must revert on the OZ nonReentrant guard.
         *
         * @param attackZapOut - true to re-enter zapOut, false for zapIn.
         * @returns The armed { evil, evilZap } pair ready for an outer zapIn.
         */
        async function deployReentrantZap(
            attackZapOut: boolean
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ): Promise<{ evil: any; evilZap: any }> {
            const Evil = await ethers.getContractFactory('ReentrantZapToken');
            const evil = await Evil.deploy();

            // Register an XOM/evil pool so the LPZap constructor passes.
            await mockRWAAMM.setPool(
                await xom.getAddress(),
                await evil.getAddress(),
                await mockPool.getAddress()
            );

            const LPZap = await ethers.getContractFactory('LPZap');
            const evilZap = await LPZap.deploy(
                await mockRWAAMM.getAddress(),
                await xom.getAddress(),
                await evil.getAddress(),
                overflowPoolAddr
            );

            // Fund + approve user, then arm the reentrancy payload.
            await evil.mint(user1.address, ZAP_AMOUNT);
            await evil.connect(user1).approve(
                await evilZap.getAddress(), ZAP_AMOUNT
            );
            await evil.arm(await evilZap.getAddress(), attackZapOut);

            return { evil, evilZap };
        }

        it('blocks a malicious token re-entering zapIn from transferFrom', async function () {
            const { evilZap } = await deployReentrantZap(false);
            const deadline = await futureDeadline();

            // usdc.safeTransferFrom re-enters zapIn → guard reverts.
            await expect(
                evilZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline)
            ).to.be.revertedWithCustomError(
                evilZap, 'ReentrancyGuardReentrantCall'
            );
        });

        it('blocks cross-function reentrancy into zapOut during zapIn', async function () {
            const { evilZap } = await deployReentrantZap(true);
            const deadline = await futureDeadline();

            // The nonReentrant guard is shared: re-entering zapOut mid-zapIn
            // must also revert.
            await expect(
                evilZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline)
            ).to.be.revertedWithCustomError(
                evilZap, 'ReentrancyGuardReentrantCall'
            );
        });
    });

    // ================================================================
    //  INTEGRATION: ZAP IN THEN ZAP OUT
    // ================================================================

    describe('Integration: zapIn then zapOut round-trip', function () {
        it('should allow a full round-trip from USDC to LP and back to USDC', async function () {
            const deadline = await futureDeadline();

            // Zap in
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            const usdcAfterZapIn = await usdc.balanceOf(user1.address);
            const lpBalance = await mockPool.balanceOf(user1.address);
            expect(lpBalance).to.be.gt(0n);

            // Zap out
            const deadline2 = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), lpBalance);
            await lpZap.connect(user1).zapOut(lpBalance, 0, 0, deadline2);

            const usdcAfterZapOut = await usdc.balanceOf(user1.address);
            const lpAfter = await mockPool.balanceOf(user1.address);

            // LP tokens should be fully burned
            expect(lpAfter).to.equal(0n);

            // User should have recovered some USDC (less due to fees/slippage in the mock)
            expect(usdcAfterZapOut).to.be.gt(usdcAfterZapIn);
        });

        it('contract should hold zero balances after all operations', async function () {
            const deadline = await futureDeadline();

            // Zap in
            await usdc.connect(user1).approve(await lpZap.getAddress(), ZAP_AMOUNT);
            await lpZap.connect(user1).zapIn(ZAP_AMOUNT, 0, 0, deadline);

            // Zap out
            const lpBalance = await mockPool.balanceOf(user1.address);
            const deadline2 = await futureDeadline();
            await mockPool.connect(user1).approve(await lpZap.getAddress(), lpBalance);
            await lpZap.connect(user1).zapOut(lpBalance, 0, 0, deadline2);

            // Verify LPZap holds nothing
            const zapAddr = await lpZap.getAddress();
            expect(await xom.balanceOf(zapAddr)).to.equal(0n);
            expect(await usdc.balanceOf(zapAddr)).to.equal(0n);
            expect(await mockPool.balanceOf(zapAddr)).to.equal(0n);
        });
    });
});
