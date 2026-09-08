/**
 * @file RWAAMMAdapter.test.ts
 * @description Tests for RWAAMMAdapter contract
 *
 * Tests cover:
 * - Deployment and constructor validation
 * - executeSwap() routing through MockRWAAMM (with onlyRouter)
 * - getAmountOut() delegation to MockRWAAMM.getQuote()
 * - Balance-before/after accounting
 * - Approval cleanup after swap
 * - Access control (onlyRouter)
 * - Input validation (zero address, zero amount)
 * - Edge cases
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('RWAAMMAdapter', function () {
    let adapter: any;
    let mockRWAAMM: any;
    let tokenIn: any;
    let tokenOut: any;

    let _owner: any;
    let router: any;
    let user: any;
    let recipient: any;

    const EXCHANGE_RATE = ethers.parseEther('2'); // 1 tokenIn = 2 tokenOut
    const PROTOCOL_FEE_BPS = 30;
    const BPS = 10000;

    beforeEach(async function () {
        [_owner, router, user, recipient] = await ethers.getSigners();

        // Deploy mock tokens
        const MockToken = await ethers.getContractFactory('MockXOMToken');
        tokenIn = await MockToken.deploy();
        tokenOut = await MockToken.deploy();

        // Deploy MockRWAAMM
        const MockRWAAMM = await ethers.getContractFactory('MockRWAAMM');
        mockRWAAMM = await MockRWAAMM.deploy(EXCHANGE_RATE);
        await mockRWAAMM.waitForDeployment();

        // Deploy RWAAMMAdapter with router
        const RWAAMMAdapter = await ethers.getContractFactory('RWAAMMAdapter');
        adapter = await RWAAMMAdapter.deploy(
            await mockRWAAMM.getAddress(),
            router.address
        );
        await adapter.waitForDeployment();

        // Fund MockRWAAMM with tokenOut (it needs to send output)
        await tokenOut.mint(await mockRWAAMM.getAddress(), ethers.parseEther('1000000'));

        // Fund router with tokenIn (router is the caller for executeSwap)
        await tokenIn.mint(router.address, ethers.parseEther('10000'));

        // Router approves adapter
        await tokenIn.connect(router).approve(await adapter.getAddress(), ethers.MaxUint256);
    });

    // ================================================================
    //  DEPLOYMENT
    // ================================================================

    describe('Deployment', function () {
        it('should set RWAAMM reference correctly', async function () {
            expect(await adapter.rwaamm()).to.equal(await mockRWAAMM.getAddress());
        });

        it('should set router reference correctly', async function () {
            expect(await adapter.router()).to.equal(router.address);
        });

        it('should reject zero address for RWAAMM', async function () {
            const RWAAMMAdapter = await ethers.getContractFactory('RWAAMMAdapter');
            await expect(
                RWAAMMAdapter.deploy(ethers.ZeroAddress, router.address)
            ).to.be.revertedWithCustomError(RWAAMMAdapter, 'ZeroAddress');
        });

        it('should reject zero address for router', async function () {
            const RWAAMMAdapter = await ethers.getContractFactory('RWAAMMAdapter');
            await expect(
                RWAAMMAdapter.deploy(await mockRWAAMM.getAddress(), ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(RWAAMMAdapter, 'ZeroAddress');
        });
    });

    // ================================================================
    //  ACCESS CONTROL
    // ================================================================

    describe('Access Control', function () {
        it('should reject executeSwap from non-router', async function () {
            const amountIn = ethers.parseEther('100');

            // Fund user and approve
            await tokenIn.mint(user.address, ethers.parseEther('10000'));
            await tokenIn.connect(user).approve(await adapter.getAddress(), ethers.MaxUint256);

            await expect(
                adapter.connect(user).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    amountIn,
                    recipient.address
                )
            ).to.be.revertedWithCustomError(adapter, 'OnlyRouter');
        });

        it('should allow executeSwap from router', async function () {
            const amountIn = ethers.parseEther('100');

            // Should not revert
            await adapter.connect(router).executeSwap(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );
        });
    });

    // ================================================================
    //  INPUT VALIDATION
    // ================================================================

    describe('Input Validation', function () {
        it('should reject zero tokenIn address', async function () {
            await expect(
                adapter.connect(router).executeSwap(
                    ethers.ZeroAddress,
                    await tokenOut.getAddress(),
                    ethers.parseEther('100'),
                    recipient.address
                )
            ).to.be.revertedWithCustomError(adapter, 'ZeroAddress');
        });

        it('should reject zero tokenOut address', async function () {
            await expect(
                adapter.connect(router).executeSwap(
                    await tokenIn.getAddress(),
                    ethers.ZeroAddress,
                    ethers.parseEther('100'),
                    recipient.address
                )
            ).to.be.revertedWithCustomError(adapter, 'ZeroAddress');
        });

        it('should reject zero amountIn', async function () {
            await expect(
                adapter.connect(router).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    0,
                    recipient.address
                )
            ).to.be.revertedWithCustomError(adapter, 'ZeroAmount');
        });

        it('should reject zero recipient', async function () {
            await expect(
                adapter.connect(router).executeSwap(
                    await tokenIn.getAddress(),
                    await tokenOut.getAddress(),
                    ethers.parseEther('100'),
                    ethers.ZeroAddress
                )
            ).to.be.revertedWithCustomError(adapter, 'ZeroAddress');
        });
    });

    // ================================================================
    //  getAmountOut
    // ================================================================

    describe('getAmountOut', function () {
        it('should return correct quote from RWAAMM', async function () {
            const amountIn = ethers.parseEther('100');
            const amountOut = await adapter.getAmountOut(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn
            );

            // Expected: (100 - 0.3% fee) * 2 = 99.7 * 2 = 199.4
            const fee = (amountIn * BigInt(PROTOCOL_FEE_BPS)) / BigInt(BPS);
            const afterFee = amountIn - fee;
            const expected = (afterFee * EXCHANGE_RATE) / ethers.parseEther('1');

            expect(amountOut).to.equal(expected);
        });

        it('should handle small amounts', async function () {
            const amountIn = BigInt(1000); // 1000 wei
            const amountOut = await adapter.getAmountOut(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn
            );

            // Small amount, some rounding expected
            expect(amountOut).to.be.gte(0);
        });
    });

    // ================================================================
    //  executeSwap
    // ================================================================

    describe('executeSwap', function () {
        it('should execute swap and send output to recipient', async function () {
            const amountIn = ethers.parseEther('100');

            const balBefore = await tokenOut.balanceOf(recipient.address);

            const amountOut = await adapter.connect(router).executeSwap.staticCall(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            await adapter.connect(router).executeSwap(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            const balAfter = await tokenOut.balanceOf(recipient.address);
            expect(balAfter - balBefore).to.equal(amountOut);
        });

        it('should forward the recipient as onBehalfOf so compliance targets the end user (not the adapter)', async function () {
            const amountIn = ethers.parseEther('100');

            await adapter.connect(router).executeSwap(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            // The adapter is msg.sender to the RWAAMM; passing onBehalfOf=0
            // would make the compliance oracle verify the adapter and bypass
            // per-user RWA compliance. The fix forwards `recipient`.
            expect(await mockRWAAMM.lastOnBehalfOf()).to.equal(recipient.address);
            expect(await mockRWAAMM.lastOnBehalfOf()).to.not.equal(
                await adapter.getAddress()
            );
        });

        it('should transfer tokenIn from router', async function () {
            const amountIn = ethers.parseEther('100');
            const balBefore = await tokenIn.balanceOf(router.address);

            await adapter.connect(router).executeSwap(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            const balAfter = await tokenIn.balanceOf(router.address);
            expect(balBefore - balAfter).to.equal(amountIn);
        });

        it('should return correct amountOut', async function () {
            const amountIn = ethers.parseEther('100');

            const amountOut = await adapter.connect(router).executeSwap.staticCall(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            // Should match getAmountOut
            const expectedOut = await adapter.getAmountOut(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn
            );

            expect(amountOut).to.equal(expectedOut);
        });

        it('should clean up token approval after swap', async function () {
            const amountIn = ethers.parseEther('100');

            await adapter.connect(router).executeSwap(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            // Check that adapter's approval to RWAAMM is zero
            const allowance = await tokenIn.allowance(
                await adapter.getAddress(),
                await mockRWAAMM.getAddress()
            );
            expect(allowance).to.equal(0);
        });

        it('should work with different exchange rates', async function () {
            // Change to 0.5:1
            await mockRWAAMM.setExchangeRate(ethers.parseEther('0.5'));

            const amountIn = ethers.parseEther('100');
            const amountOut = await adapter.connect(router).executeSwap.staticCall(
                await tokenIn.getAddress(),
                await tokenOut.getAddress(),
                amountIn,
                recipient.address
            );

            // Expected: (100 - 0.3%) * 0.5 = 49.85
            const fee = (amountIn * BigInt(PROTOCOL_FEE_BPS)) / BigInt(BPS);
            const afterFee = amountIn - fee;
            const expected = (afterFee * ethers.parseEther('0.5')) / ethers.parseEther('1');

            expect(amountOut).to.equal(expected);
        });
    });
});
