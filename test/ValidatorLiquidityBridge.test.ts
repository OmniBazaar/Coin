/**
 * @file ValidatorLiquidityBridge.test.ts
 * @description Comprehensive tests for the ValidatorLiquidityBridge contract
 *
 * Tests cover:
 * - Deployment & constructor validation
 * - Deposit / withdraw by bridge managers
 * - executeSwap via router (ISwapAdapter)
 * - Public swap() with slippage + deadline
 * - Fixed-rate and RWAAMM oracle pricing modes
 * - Daily volume limits + per-swap caps + min swap size
 * - Per-user daily volume limits
 * - Volume normalization for cross-decimal tokens
 * - MAX_RATE ceiling enforcement
 * - safeSetRate atomic pause→set→unpause
 * - Oracle deviation check for RWAAMM mode
 * - try/catch RWAAMM graceful failure
 * - Supported token whitelist
 * - Pause / unpause
 * - Emergency withdraw
 * - getAmountOut view function
 * - remainingDailyVolume + remainingUserDailyVolume helpers
 * - Access control for all roles
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('ValidatorLiquidityBridge', function () {
    let bridge: any;
    let mockRWAAMM: any;
    let xom: any;
    let usdc: any;

    let owner: any;
    let manager: any;
    let router: any;
    let user1: any;
    let user2: any;

    /** Rate precision constant from the contract */
    const _RATE_PRECISION = ethers.parseEther('1'); // 1e18

    /**
     * Fixed rates for testing:
     * XOM (18 dec) → USDC (18 dec in mock): $0.004 = 4e15 per 1e18
     * But since mock tokens are all 18 decimals, we use 1:1 for simplicity.
     *
     * XOM → USDC rate: 0.004 * 1e18 = 4e15 (4000000000000000)
     * USDC → XOM rate: 250 * 1e18 = 250e18
     *
     * But with 18-decimal mock tokens (same decimals):
     * XOM → USDC: amountOut = amountIn * rate / 1e18
     *   For 1e18 XOM → 0.004e18 USDC: rate = 0.004e18 = 4e15
     *   For 1000e18 XOM → 4e18 USDC: amountOut = 1000e18 * 4e15 / 1e18 = 4e18 ✓
     *
     * USDC → XOM: amountOut = amountIn * rate / 1e18
     *   For 1e18 USDC → 250e18 XOM: rate = 250e18
     *   For 4e18 USDC → 1000e18 XOM: amountOut = 4e18 * 250e18 / 1e18 = 1000e18 ✓
     */
    const RATE_XOM_TO_USDC = ethers.parseUnits('4', 15); // 4e15
    const RATE_USDC_TO_XOM = ethers.parseEther('250');    // 250e18

    /** Amounts for testing */
    const DEPOSIT_XOM = ethers.parseEther('125000000');  // 125M XOM
    const _DEPOSIT_USDC = ethers.parseEther('500000');     // 500K USDC
    const SWAP_AMOUNT = ethers.parseEther('1000');        // 1000 tokens
    const SEED_AMOUNT = ethers.parseEther('200000000');   // 200M seed
    const MAX_SWAP_SIZE = ethers.parseEther('10000000');  // 10M max swap
    const DAILY_LIMIT = ethers.parseEther('50000000');    // 50M daily

    /** Role hashes */
    let BRIDGE_MANAGER_ROLE: string;
    let DEFAULT_ADMIN_ROLE: string;

    /** Exchange rate for MockRWAAMM: 1:1 for simplicity */
    const ORACLE_EXCHANGE_RATE = ethers.parseEther('1');

    beforeEach(async function () {
        [owner, manager, router, user1, user2] = await ethers.getSigners();

        // Deploy mock tokens (18 decimals each)
        const MockToken = await ethers.getContractFactory('MockXOMToken');
        xom = await MockToken.deploy();
        usdc = await MockToken.deploy();

        // Deploy MockRWAAMM for oracle pricing mode
        const MockRWAAMM = await ethers.getContractFactory(
            'MockRWAAMMForZap'
        );
        mockRWAAMM = await MockRWAAMM.deploy(ORACLE_EXCHANGE_RATE);

        // Deploy bridge
        const Bridge = await ethers.getContractFactory(
            'ValidatorLiquidityBridge'
        );
        bridge = await Bridge.deploy(
            await mockRWAAMM.getAddress(),
            router.address,
            owner.address,
            MAX_SWAP_SIZE,
            DAILY_LIMIT
        );

        // Compute role hashes
        BRIDGE_MANAGER_ROLE = await bridge.BRIDGE_MANAGER_ROLE();
        DEFAULT_ADMIN_ROLE = await bridge.DEFAULT_ADMIN_ROLE();

        // Grant manager role
        await bridge.grantRole(BRIDGE_MANAGER_ROLE, manager.address);

        // Whitelist tokens
        await bridge.setSupportedToken(await xom.getAddress(), true);
        await bridge.setSupportedToken(await usdc.getAddress(), true);

        // Set fixed rates
        await bridge.connect(manager).setRate(
            await xom.getAddress(),
            await usdc.getAddress(),
            RATE_XOM_TO_USDC
        );
        await bridge.connect(manager).setRate(
            await usdc.getAddress(),
            await xom.getAddress(),
            RATE_USDC_TO_XOM
        );

        // Mint tokens to manager for deposits
        await xom.mint(manager.address, SEED_AMOUNT);
        await usdc.mint(manager.address, SEED_AMOUNT);

        // Mint tokens to user1 for swaps
        await xom.mint(user1.address, SEED_AMOUNT);
        await usdc.mint(user1.address, SEED_AMOUNT);
    });

    // ═══════════════════════════════════════════════════════════════════
    //                   DEPLOYMENT & CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    describe('Deployment', function () {
        it('sets immutables correctly', async function () {
            expect(await bridge.rwaamm()).to.equal(
                await mockRWAAMM.getAddress()
            );
            expect(await bridge.router()).to.equal(router.address);
        });

        it('sets initial limits', async function () {
            expect(await bridge.maxSwapSize()).to.equal(MAX_SWAP_SIZE);
            expect(await bridge.dailyVolumeLimit()).to.equal(DAILY_LIMIT);
        });

        it('starts in FIXED_RATE pricing mode', async function () {
            expect(await bridge.pricingMode()).to.equal(0); // FIXED_RATE
        });

        it('grants admin and manager roles to deployer', async function () {
            expect(
                await bridge.hasRole(DEFAULT_ADMIN_ROLE, owner.address)
            ).to.be.true;
            expect(
                await bridge.hasRole(BRIDGE_MANAGER_ROLE, owner.address)
            ).to.be.true;
        });

        it('reverts on zero RWAAMM address', async function () {
            const Bridge = await ethers.getContractFactory(
                'ValidatorLiquidityBridge'
            );
            await expect(
                Bridge.deploy(
                    ethers.ZeroAddress,
                    router.address,
                    owner.address,
                    MAX_SWAP_SIZE,
                    DAILY_LIMIT
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
        });

        it('reverts on zero router address', async function () {
            const Bridge = await ethers.getContractFactory(
                'ValidatorLiquidityBridge'
            );
            await expect(
                Bridge.deploy(
                    await mockRWAAMM.getAddress(),
                    ethers.ZeroAddress,
                    owner.address,
                    MAX_SWAP_SIZE,
                    DAILY_LIMIT
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
        });

        it('reverts on zero admin address', async function () {
            const Bridge = await ethers.getContractFactory(
                'ValidatorLiquidityBridge'
            );
            await expect(
                Bridge.deploy(
                    await mockRWAAMM.getAddress(),
                    router.address,
                    ethers.ZeroAddress,
                    MAX_SWAP_SIZE,
                    DAILY_LIMIT
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
        });

        it('reverts on excessive daily volume limit', async function () {
            const Bridge = await ethers.getContractFactory(
                'ValidatorLiquidityBridge'
            );
            const tooHigh = ethers.parseEther('20000000000'); // > 10B
            await expect(
                Bridge.deploy(
                    await mockRWAAMM.getAddress(),
                    router.address,
                    owner.address,
                    MAX_SWAP_SIZE,
                    tooHigh
                )
            ).to.be.revertedWithCustomError(bridge, 'VolumeLimitTooHigh');
        });

        it('exposes MAX_RATE constant', async function () {
            const maxRate = await bridge.MAX_RATE();
            expect(maxRate).to.equal(ethers.parseUnits('1', 40));
        });

        it('exposes MAX_BPS constant', async function () {
            expect(await bridge.MAX_BPS()).to.equal(10000n);
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                   DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════

    describe('Deposit', function () {
        it('deposits tokens and updates reserves', async function () {
            const amount = ethers.parseEther('1000');
            await xom.connect(manager).approve(
                await bridge.getAddress(), amount
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), amount
            );

            expect(await bridge.reserves(await xom.getAddress())).to.equal(
                amount
            );
        });

        it('emits Deposited event', async function () {
            const amount = ethers.parseEther('5000');
            await xom.connect(manager).approve(
                await bridge.getAddress(), amount
            );
            await expect(
                bridge.connect(manager).deposit(
                    await xom.getAddress(), amount
                )
            )
                .to.emit(bridge, 'Deposited')
                .withArgs(manager.address, await xom.getAddress(), amount);
        });

        it('reverts for unsupported token', async function () {
            const fakeToken = ethers.Wallet.createRandom().address;
            await expect(
                bridge.connect(manager).deposit(fakeToken, 1000)
            ).to.be.revertedWithCustomError(bridge, 'UnsupportedToken');
        });

        it('reverts for zero amount', async function () {
            await expect(
                bridge.connect(manager).deposit(
                    await xom.getAddress(), 0
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAmount');
        });

        it('reverts for non-manager', async function () {
            await expect(
                bridge.connect(user1).deposit(
                    await xom.getAddress(),
                    ethers.parseEther('100')
                )
            ).to.be.reverted; // AccessControl revert
        });
    });

    describe('Withdraw', function () {
        beforeEach(async function () {
            const amount = ethers.parseEther('10000');
            await xom.connect(manager).approve(
                await bridge.getAddress(), amount
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), amount
            );
        });

        it('withdraws tokens and updates reserves', async function () {
            const withdrawAmount = ethers.parseEther('3000');
            const before = await xom.balanceOf(user2.address);

            await bridge.connect(manager).withdraw(
                await xom.getAddress(), withdrawAmount, user2.address
            );

            expect(await bridge.reserves(await xom.getAddress())).to.equal(
                ethers.parseEther('7000')
            );
            expect(await xom.balanceOf(user2.address)).to.equal(
                before + withdrawAmount
            );
        });

        it('emits Withdrawn event', async function () {
            const amount = ethers.parseEther('2000');
            await expect(
                bridge.connect(manager).withdraw(
                    await xom.getAddress(), amount, user2.address
                )
            )
                .to.emit(bridge, 'Withdrawn')
                .withArgs(
                    manager.address,
                    await xom.getAddress(),
                    amount,
                    user2.address
                );
        });

        it('reverts if insufficient reserves', async function () {
            await expect(
                bridge.connect(manager).withdraw(
                    await xom.getAddress(),
                    ethers.parseEther('99999'),
                    user2.address
                )
            ).to.be.revertedWithCustomError(
                bridge, 'InsufficientReserves'
            );
        });

        it('reverts for zero address destination', async function () {
            await expect(
                bridge.connect(manager).withdraw(
                    await xom.getAddress(),
                    ethers.parseEther('100'),
                    ethers.ZeroAddress
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
        });

        it('reverts for zero amount', async function () {
            await expect(
                bridge.connect(manager).withdraw(
                    await xom.getAddress(), 0, user2.address
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAmount');
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                   FIXED-RATE SWAP VIA ROUTER
    // ═══════════════════════════════════════════════════════════════════

    describe('executeSwap (router)', function () {
        beforeEach(async function () {
            // Manager deposits XOM reserves
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('swaps USDC → XOM at fixed rate via router', async function () {
            const usdcIn = ethers.parseEther('4'); // 4 USDC
            // Expected: 4e18 * 250e18 / 1e18 = 1000e18 XOM
            const expectedXOM = ethers.parseEther('1000');

            // Router transfers USDC to bridge and calls executeSwap
            await usdc.mint(router.address, usdcIn);
            await usdc.connect(router).approve(
                await bridge.getAddress(), usdcIn
            );

            const balBefore = await xom.balanceOf(user1.address);
            await bridge.connect(router).executeSwap(
                await usdc.getAddress(),
                await xom.getAddress(),
                usdcIn,
                user1.address
            );
            const balAfter = await xom.balanceOf(user1.address);

            expect(balAfter - balBefore).to.equal(expectedXOM);
        });

        it('updates reserves correctly', async function () {
            const usdcIn = ethers.parseEther('4');
            const expectedXOM = ethers.parseEther('1000');

            await usdc.mint(router.address, usdcIn);
            await usdc.connect(router).approve(
                await bridge.getAddress(), usdcIn
            );

            await bridge.connect(router).executeSwap(
                await usdc.getAddress(),
                await xom.getAddress(),
                usdcIn,
                user1.address
            );

            expect(await bridge.reserves(await xom.getAddress())).to.equal(
                DEPOSIT_XOM - expectedXOM
            );
            expect(await bridge.reserves(await usdc.getAddress())).to.equal(
                usdcIn
            );
        });

        it('emits BridgeSwapExecuted event', async function () {
            const usdcIn = ethers.parseEther('4');

            await usdc.mint(router.address, usdcIn);
            await usdc.connect(router).approve(
                await bridge.getAddress(), usdcIn
            );

            await expect(
                bridge.connect(router).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    usdcIn,
                    user1.address
                )
            ).to.emit(bridge, 'BridgeSwapExecuted');
        });

        it('reverts when called by non-router', async function () {
            await expect(
                bridge.connect(user1).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    SWAP_AMOUNT,
                    user1.address
                )
            ).to.be.revertedWithCustomError(bridge, 'OnlyRouter');
        });

        it('reverts on unsupported token', async function () {
            const fakeToken = ethers.Wallet.createRandom().address;
            await expect(
                bridge.connect(router).executeSwap(
                    fakeToken,
                    await xom.getAddress(),
                    SWAP_AMOUNT,
                    user1.address
                )
            ).to.be.revertedWithCustomError(bridge, 'UnsupportedToken');
        });

        it('reverts on insufficient reserves', async function () {
            // Try to buy more XOM than deposited
            const tooMuch = ethers.parseEther('600000'); // 600K USDC
            // 600K * 250 = 150M XOM > 125M deposit

            await usdc.mint(router.address, tooMuch);
            await usdc.connect(router).approve(
                await bridge.getAddress(), tooMuch
            );

            await expect(
                bridge.connect(router).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    tooMuch,
                    user1.address
                )
            ).to.be.revertedWithCustomError(
                bridge, 'InsufficientReserves'
            );
        });

        it('reverts on zero amount', async function () {
            await expect(
                bridge.connect(router).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    0,
                    user1.address
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAmount');
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    PUBLIC swap()
    // ═══════════════════════════════════════════════════════════════════

    describe('swap (public)', function () {
        beforeEach(async function () {
            // Deposit XOM reserves
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('swaps USDC → XOM at fixed rate', async function () {
            const usdcIn = ethers.parseEther('4');
            const expectedXOM = ethers.parseEther('1000');
            const deadline = (await time.latest()) + 600;

            await usdc.connect(user1).approve(
                await bridge.getAddress(), usdcIn
            );

            const before = await xom.balanceOf(user1.address);
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                usdcIn,
                expectedXOM, // minAmountOut
                deadline
            );
            const after = await xom.balanceOf(user1.address);

            expect(after - before).to.equal(expectedXOM);
        });

        it('reverts on expired deadline', async function () {
            const pastDeadline = (await time.latest()) - 1;

            await usdc.connect(user1).approve(
                await bridge.getAddress(), SWAP_AMOUNT
            );

            await expect(
                bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    SWAP_AMOUNT,
                    0,
                    pastDeadline
                )
            ).to.be.revertedWithCustomError(bridge, 'DeadlineExpired');
        });

        it('reverts on slippage exceeded', async function () {
            const usdcIn = ethers.parseEther('4');
            // Actual output = 1000 XOM. Set minAmountOut = 2000 XOM
            const tooHighMin = ethers.parseEther('2000');
            const deadline = (await time.latest()) + 600;

            await usdc.connect(user1).approve(
                await bridge.getAddress(), usdcIn
            );

            await expect(
                bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    usdcIn,
                    tooHighMin,
                    deadline
                )
            ).to.be.revertedWithCustomError(
                bridge, 'SlippageExceeded'
            );
        });

        it('swaps XOM → USDC at fixed rate', async function () {
            // Deposit USDC reserves first
            const usdcDeposit = ethers.parseEther('10000');
            await usdc.connect(manager).approve(
                await bridge.getAddress(), usdcDeposit
            );
            await bridge.connect(manager).deposit(
                await usdc.getAddress(), usdcDeposit
            );

            const xomIn = ethers.parseEther('1000'); // 1000 XOM
            // Expected: 1000e18 * 4e15 / 1e18 = 4e18 = 4 USDC
            const expectedUSDC = ethers.parseEther('4');
            const deadline = (await time.latest()) + 600;

            await xom.connect(user1).approve(
                await bridge.getAddress(), xomIn
            );

            const before = await usdc.balanceOf(user1.address);
            await bridge.connect(user1).swap(
                await xom.getAddress(),
                await usdc.getAddress(),
                xomIn,
                expectedUSDC,
                deadline
            );
            const after = await usdc.balanceOf(user1.address);

            expect(after - before).to.equal(expectedUSDC);
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    RWAAMM ORACLE MODE
    // ═══════════════════════════════════════════════════════════════════

    describe('RWAAMM Oracle pricing mode', function () {
        beforeEach(async function () {
            // Deposit XOM reserves
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );

            // Set up mock RWAAMM pool (needed for getQuote)
            const xomAddr = await xom.getAddress();
            const usdcAddr = await usdc.getAddress();

            const MockRWAPool = await ethers.getContractFactory(
                'contracts/mocks/MockRWAAMMForZap.sol:MockRWAPool'
            );
            const [t0, t1] = xomAddr.toLowerCase() < usdcAddr.toLowerCase()
                ? [xomAddr, usdcAddr]
                : [usdcAddr, xomAddr];
            const pool = await MockRWAPool.deploy(t0, t1);
            await mockRWAAMM.setPool(xomAddr, usdcAddr, await pool.getAddress());

            // Set reserves so getQuote works
            const reserveAmount = ethers.parseEther('1000000');
            await pool.setReserves(reserveAmount, reserveAmount);

            // Configure the oracle deviation cap BEFORE enabling oracle mode.
            // setPricingMode(RWAAMM_ORACLE) now fails closed unless a non-zero
            // cap is set (manipulation guard). MAX_BPS = no effective constraint
            // for this test, matching its original intent.
            await bridge.connect(manager).setMaxOracleDeviationBps(10000);

            // Seed RWAAMM with tokens (getQuote is view, not needed)
            // Switch to oracle mode
            await bridge.connect(manager).setPricingMode(1); // RWAAMM_ORACLE
        });

        it('uses RWAAMM getQuote for pricing', async function () {
            // Oracle rate is 1:1 for mock
            const usdcIn = ethers.parseEther('100');
            const deadline = (await time.latest()) + 600;

            await usdc.connect(user1).approve(
                await bridge.getAddress(), usdcIn
            );

            const before = await xom.balanceOf(user1.address);
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                usdcIn,
                0, // No slippage check for this test
                deadline
            );
            const after = await xom.balanceOf(user1.address);

            // 1:1 rate minus 0.3% fee from mock = ~99.7 tokens
            // MockRWAAMMForZap charges protocolFeeBps (30bps)
            const fee = (usdcIn * 30n) / 10000n;
            const expectedOut = usdcIn - fee;
            expect(after - before).to.equal(expectedOut);
        });

        it('emits PricingModeUpdated event', async function () {
            // Already in RWAAMM_ORACLE mode. Switch back.
            await expect(
                bridge.connect(manager).setPricingMode(0) // FIXED_RATE
            )
                .to.emit(bridge, 'PricingModeUpdated')
                .withArgs(1, 0);
        });

        it('returns 0 from getAmountOut when RWAAMM reverts',
            async function () {
                // Deploy a bridge whose rwaamm is a non-RWAAMM contract.
                // Calling getQuote() on a token contract will revert
                // (ABI mismatch), which exercises the try/catch path.
                const Bridge = await ethers.getContractFactory(
                    'ValidatorLiquidityBridge'
                );
                const revertBridge = await Bridge.deploy(
                    await xom.getAddress(), // NOT a real RWAAMM
                    router.address,
                    owner.address,
                    MAX_SWAP_SIZE,
                    DAILY_LIMIT
                );
                await revertBridge.setSupportedToken(
                    await usdc.getAddress(), true
                );
                await revertBridge.setSupportedToken(
                    await xom.getAddress(), true
                );
                await revertBridge.grantRole(
                    BRIDGE_MANAGER_ROLE, manager.address
                );

                // No deposit needed — getAmountOut is a view function
                // and will return 0 from the try/catch before reaching
                // the reserve check.

                // Deviation cap must be set before enabling oracle mode.
                await revertBridge.connect(manager).setMaxOracleDeviationBps(500);

                // Switch to RWAAMM_ORACLE mode
                await revertBridge.connect(manager).setPricingMode(1);

                // getQuote on a token contract will revert → try/catch
                // returns 0
                const out = await revertBridge.getAmountOut(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    SWAP_AMOUNT
                );
                expect(out).to.equal(0n);
            }
        );

        it('blocks swap when oracle deviates too far', async function () {
            // Set rate to 1:1 (matching oracle baseline) so the only
            // deviation is the mock RWAAMM's 30bps fee (0.3%).
            await bridge.connect(manager).setRate(
                await usdc.getAddress(),
                await xom.getAddress(),
                ethers.parseEther('1')
            );

            // Set tolerance to 10 bps (0.1%) — tighter than the
            // 30bps (0.3%) fee, so deviation check rejects it.
            await bridge.connect(manager).setMaxOracleDeviationBps(10);

            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                ethers.parseEther('100')
            );
            expect(out).to.equal(0n);
        });

        it('allows swap when oracle is within deviation', async function () {
            // Set rate to 1:1 (matching oracle baseline) so the only
            // deviation is the mock RWAAMM's 30bps fee (0.3%).
            await bridge.connect(manager).setRate(
                await usdc.getAddress(),
                await xom.getAddress(),
                ethers.parseEther('1')
            );

            // Set tolerance to 9900 bps (99%) — much wider than
            // 0.3% fee deviation, so the check passes.
            await bridge.connect(manager).setMaxOracleDeviationBps(9900);

            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                ethers.parseEther('100')
            );
            // The mock returns ~99.7e18 (1:1 minus 30bps fee)
            expect(out).to.be.gt(0n);
        });

        it('blocks enabling RWAAMM_ORACLE mode while the deviation cap is unset',
            async function () {
                // Security: enabling oracle pricing with maxOracleDeviationBps
                // == 0 disables the manipulation guard (the deviation check
                // short-circuits to true), exposing reserves to a flash-priced
                // drain. setPricingMode must fail closed.
                const Bridge = await ethers.getContractFactory(
                    'ValidatorLiquidityBridge'
                );
                const freshBridge = await Bridge.deploy(
                    await mockRWAAMM.getAddress(),
                    router.address,
                    owner.address,
                    MAX_SWAP_SIZE,
                    DAILY_LIMIT
                );
                await freshBridge.grantRole(
                    BRIDGE_MANAGER_ROLE, manager.address
                );

                // Default cap is 0 → switching to oracle mode reverts.
                expect(await freshBridge.maxOracleDeviationBps()).to.equal(0n);
                await expect(
                    freshBridge.connect(manager).setPricingMode(1)
                ).to.be.revertedWithCustomError(
                    freshBridge, 'OracleDeviationNotSet'
                );

                // After setting a cap, the switch succeeds.
                await freshBridge.connect(manager).setMaxOracleDeviationBps(500);
                await expect(
                    freshBridge.connect(manager).setPricingMode(1)
                ).to.emit(freshBridge, 'PricingModeUpdated');
            }
        );
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    VOLUME LIMITS
    // ═══════════════════════════════════════════════════════════════════

    describe('Volume limits', function () {
        beforeEach(async function () {
            // Deposit large XOM reserve
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('enforces maxSwapSize', async function () {
            const tooBig = MAX_SWAP_SIZE + 1n;

            await usdc.mint(router.address, tooBig);
            await usdc.connect(router).approve(
                await bridge.getAddress(), tooBig
            );

            await expect(
                bridge.connect(router).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    tooBig,
                    user1.address
                )
            ).to.be.revertedWithCustomError(bridge, 'SwapTooLarge');
        });

        it('enforces dailyVolumeLimit', async function () {
            // Set a small daily limit
            await bridge.connect(manager).setDailyVolumeLimit(
                ethers.parseEther('100')
            );

            const swapAmt = ethers.parseEther('60');
            const deadline = (await time.latest()) + 600;

            // First swap: 60 tokens — OK
            await usdc.connect(user1).approve(
                await bridge.getAddress(), swapAmt * 2n
            );
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );

            // Second swap: 60 tokens — exceeds 100 limit
            await expect(
                bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline + 600
                )
            ).to.be.revertedWithCustomError(
                bridge, 'DailyVolumeLimitExceeded'
            );
        });

        it('resets daily volume on new day', async function () {
            await bridge.connect(manager).setDailyVolumeLimit(
                ethers.parseEther('100')
            );

            const swapAmt = ethers.parseEther('80');
            const deadline = (await time.latest()) + 86400 * 2;

            // First swap: 80 tokens
            await usdc.connect(user1).approve(
                await bridge.getAddress(), swapAmt * 2n
            );
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );

            // Advance 1 day
            await time.increase(86401);

            // Second swap: 80 tokens — should succeed (new day)
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );

            // Volume should be 80 (reset)
            expect(await bridge.dailyVolumeUsed()).to.equal(swapAmt);
        });

        it('updates maxSwapSize', async function () {
            const newSize = ethers.parseEther('999');
            await expect(
                bridge.connect(manager).setMaxSwapSize(newSize)
            )
                .to.emit(bridge, 'MaxSwapSizeUpdated')
                .withArgs(MAX_SWAP_SIZE, newSize);

            expect(await bridge.maxSwapSize()).to.equal(newSize);
        });

        it('reverts on excessive daily volume limit', async function () {
            const tooHigh = ethers.parseEther('20000000000');
            await expect(
                bridge.connect(manager).setDailyVolumeLimit(tooHigh)
            ).to.be.revertedWithCustomError(
                bridge, 'VolumeLimitTooHigh'
            );
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    MIN SWAP SIZE
    // ═══════════════════════════════════════════════════════════════════

    describe('Min swap size', function () {
        beforeEach(async function () {
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('sets and emits minSwapSize', async function () {
            const minSize = ethers.parseEther('10');
            await expect(
                bridge.connect(manager).setMinSwapSize(minSize)
            )
                .to.emit(bridge, 'MinSwapSizeUpdated')
                .withArgs(0n, minSize);

            expect(await bridge.minSwapSize()).to.equal(minSize);
        });

        it('enforces minSwapSize on swap()', async function () {
            const minSize = ethers.parseEther('100');
            await bridge.connect(manager).setMinSwapSize(minSize);

            const tooSmall = ethers.parseEther('50');
            const deadline = (await time.latest()) + 600;
            await usdc.connect(user1).approve(
                await bridge.getAddress(), tooSmall
            );

            await expect(
                bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    tooSmall,
                    0,
                    deadline
                )
            ).to.be.revertedWithCustomError(bridge, 'SwapTooSmall');
        });

        it('enforces minSwapSize on executeSwap()', async function () {
            const minSize = ethers.parseEther('100');
            await bridge.connect(manager).setMinSwapSize(minSize);

            const tooSmall = ethers.parseEther('50');
            await usdc.mint(router.address, tooSmall);
            await usdc.connect(router).approve(
                await bridge.getAddress(), tooSmall
            );

            await expect(
                bridge.connect(router).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    tooSmall,
                    user1.address
                )
            ).to.be.revertedWithCustomError(bridge, 'SwapTooSmall');
        });

        it('getAmountOut returns 0 for amount below minSwapSize',
            async function () {
                const minSize = ethers.parseEther('100');
                await bridge.connect(manager).setMinSwapSize(minSize);

                const out = await bridge.getAmountOut(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    ethers.parseEther('50')
                );
                expect(out).to.equal(0n);
            }
        );

        it('allows swap at exactly minSwapSize', async function () {
            const minSize = ethers.parseEther('100');
            await bridge.connect(manager).setMinSwapSize(minSize);

            const deadline = (await time.latest()) + 600;
            await usdc.connect(user1).approve(
                await bridge.getAddress(), minSize
            );

            // Should not revert
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                minSize,
                0,
                deadline
            );
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                  PER-USER DAILY VOLUME LIMITS
    // ═══════════════════════════════════════════════════════════════════

    describe('Per-user daily volume limits', function () {
        beforeEach(async function () {
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );

            // Mint tokens for user2 as well
            await usdc.mint(user2.address, SEED_AMOUNT);
        });

        it('sets and emits perUserDailyVolumeLimit', async function () {
            const limit = ethers.parseEther('1000');
            await expect(
                bridge.connect(manager).setPerUserDailyVolumeLimit(limit)
            )
                .to.emit(bridge, 'PerUserDailyVolumeLimitUpdated')
                .withArgs(0n, limit);

            expect(await bridge.perUserDailyVolumeLimit()).to.equal(limit);
        });

        it('enforces per-user limit', async function () {
            const userLimit = ethers.parseEther('500');
            await bridge.connect(manager).setPerUserDailyVolumeLimit(
                userLimit
            );

            const swapAmt = ethers.parseEther('300');
            const deadline = (await time.latest()) + 600;

            // User1 first swap: 300 — OK
            await usdc.connect(user1).approve(
                await bridge.getAddress(), swapAmt * 2n
            );
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );

            // User1 second swap: 300 — exceeds 500 user limit
            await expect(
                bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline + 600
                )
            ).to.be.revertedWithCustomError(
                bridge, 'UserDailyVolumeLimitExceeded'
            );
        });

        it('allows different users to swap independently',
            async function () {
                const userLimit = ethers.parseEther('500');
                await bridge.connect(manager).setPerUserDailyVolumeLimit(
                    userLimit
                );

                const swapAmt = ethers.parseEther('400');
                const deadline = (await time.latest()) + 600;

                // User1 swaps 400 — OK (400 < 500 limit)
                await usdc.connect(user1).approve(
                    await bridge.getAddress(), swapAmt
                );
                await bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline
                );

                // User2 swaps 400 — also OK (separate per-user counter)
                await usdc.connect(user2).approve(
                    await bridge.getAddress(), swapAmt
                );
                await bridge.connect(user2).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline
                );
            }
        );

        it('resets per-user volume on new day', async function () {
            const userLimit = ethers.parseEther('500');
            await bridge.connect(manager).setPerUserDailyVolumeLimit(
                userLimit
            );

            const swapAmt = ethers.parseEther('400');
            const deadline = (await time.latest()) + 86400 * 2;

            await usdc.connect(user1).approve(
                await bridge.getAddress(), swapAmt * 2n
            );

            // User1 swaps 400 (80% of limit)
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );

            // Advance 1 day
            await time.increase(86401);

            // User1 can swap 400 again (reset)
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );
        });

        it('remainingUserDailyVolume returns correct values',
            async function () {
                const userLimit = ethers.parseEther('1000');
                await bridge.connect(manager).setPerUserDailyVolumeLimit(
                    userLimit
                );

                // Before any swap
                expect(
                    await bridge.remainingUserDailyVolume(user1.address)
                ).to.equal(userLimit);

                const swapAmt = ethers.parseEther('300');
                const deadline = (await time.latest()) + 600;
                await usdc.connect(user1).approve(
                    await bridge.getAddress(), swapAmt
                );
                await bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline
                );

                // After 300 swap: remaining = 700
                expect(
                    await bridge.remainingUserDailyVolume(user1.address)
                ).to.equal(ethers.parseEther('700'));
            }
        );

        it('remainingUserDailyVolume returns max when disabled',
            async function () {
                // perUserDailyVolumeLimit = 0 (default, disabled)
                expect(
                    await bridge.remainingUserDailyVolume(user1.address)
                ).to.equal(ethers.MaxUint256);
            }
        );

        it('reverts on excessive per-user limit', async function () {
            const tooHigh = ethers.parseEther('20000000000');
            await expect(
                bridge.connect(manager).setPerUserDailyVolumeLimit(
                    tooHigh
                )
            ).to.be.revertedWithCustomError(
                bridge, 'VolumeLimitTooHigh'
            );
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                  VOLUME NORMALIZATION
    // ═══════════════════════════════════════════════════════════════════

    describe('Volume normalization', function () {
        beforeEach(async function () {
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('sets and emits volumeNormalizer', async function () {
            const norm = ethers.parseUnits('1', 12); // 1e12
            await expect(
                bridge.connect(manager).setVolumeNormalizer(
                    await usdc.getAddress(), norm
                )
            )
                .to.emit(bridge, 'VolumeNormalizerUpdated')
                .withArgs(await usdc.getAddress(), norm);

            expect(
                await bridge.volumeNormalizer(await usdc.getAddress())
            ).to.equal(norm);
        });

        it('applies normalizer to daily volume tracking',
            async function () {
                // Set normalizer for USDC = 10 (each 1 USDC counts as 10)
                await bridge.connect(manager).setVolumeNormalizer(
                    await usdc.getAddress(), 10n
                );

                // Set daily limit to 1000 (in normalized units)
                await bridge.connect(manager).setDailyVolumeLimit(
                    ethers.parseEther('1000')
                );

                const swapAmt = ethers.parseEther('60');
                const deadline = (await time.latest()) + 600;

                // Swap 60 USDC → normalized = 600 (60 * 10)
                await usdc.connect(user1).approve(
                    await bridge.getAddress(), swapAmt * 2n
                );
                await bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline
                );

                // dailyVolumeUsed should be 600 (60 * normalizer 10)
                expect(await bridge.dailyVolumeUsed()).to.equal(
                    swapAmt * 10n
                );

                // Another 60 USDC → normalized 600, total 1200 > 1000 limit
                await expect(
                    bridge.connect(user1).swap(
                        await usdc.getAddress(),
                        await xom.getAddress(),
                        swapAmt,
                        0,
                        deadline + 600
                    )
                ).to.be.revertedWithCustomError(
                    bridge, 'DailyVolumeLimitExceeded'
                );
            }
        );

        it('uses raw amount when normalizer is 0 (default)',
            async function () {
                // No normalizer set (default 0 = no scaling)
                await bridge.connect(manager).setDailyVolumeLimit(
                    ethers.parseEther('100')
                );

                const swapAmt = ethers.parseEther('60');
                const deadline = (await time.latest()) + 600;
                await usdc.connect(user1).approve(
                    await bridge.getAddress(), swapAmt
                );
                await bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    swapAmt,
                    0,
                    deadline
                );

                // dailyVolumeUsed = 60 (raw, no scaling)
                expect(await bridge.dailyVolumeUsed()).to.equal(swapAmt);
            }
        );

        it('uses raw amount when normalizer is 1', async function () {
            await bridge.connect(manager).setVolumeNormalizer(
                await usdc.getAddress(), 1n
            );
            await bridge.connect(manager).setDailyVolumeLimit(
                ethers.parseEther('100')
            );

            const swapAmt = ethers.parseEther('50');
            const deadline = (await time.latest()) + 600;
            await usdc.connect(user1).approve(
                await bridge.getAddress(), swapAmt
            );
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                swapAmt,
                0,
                deadline
            );

            // normalizer = 1 → no scaling
            expect(await bridge.dailyVolumeUsed()).to.equal(swapAmt);
        });

        it('reverts setVolumeNormalizer with zero address',
            async function () {
                await expect(
                    bridge.connect(manager).setVolumeNormalizer(
                        ethers.ZeroAddress, 10n
                    )
                ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
            }
        );
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    TOKEN WHITELIST
    // ═══════════════════════════════════════════════════════════════════

    describe('Supported tokens', function () {
        it('updates token support status', async function () {
            const fakeAddr = ethers.Wallet.createRandom().address;
            await expect(
                bridge.setSupportedToken(fakeAddr, true)
            )
                .to.emit(bridge, 'TokenSupportUpdated')
                .withArgs(fakeAddr, true);

            expect(await bridge.supportedTokens(fakeAddr)).to.be.true;
        });

        it('reverts on zero address', async function () {
            await expect(
                bridge.setSupportedToken(ethers.ZeroAddress, true)
            ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
        });

        it('only admin can update support', async function () {
            await expect(
                bridge.connect(user1).setSupportedToken(
                    await xom.getAddress(), false
                )
            ).to.be.reverted; // AccessControl
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    PAUSE / UNPAUSE
    // ═══════════════════════════════════════════════════════════════════

    describe('Pause', function () {
        beforeEach(async function () {
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('pauses swap activity', async function () {
            await bridge.pause();

            await usdc.connect(user1).approve(
                await bridge.getAddress(), SWAP_AMOUNT
            );

            await expect(
                bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    SWAP_AMOUNT,
                    0,
                    (await time.latest()) + 600
                )
            ).to.be.revertedWithCustomError(bridge, 'EnforcedPause');
        });

        it('pauses executeSwap', async function () {
            await bridge.pause();

            await usdc.mint(router.address, SWAP_AMOUNT);
            await usdc.connect(router).approve(
                await bridge.getAddress(), SWAP_AMOUNT
            );

            await expect(
                bridge.connect(router).executeSwap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    SWAP_AMOUNT,
                    user1.address
                )
            ).to.be.revertedWithCustomError(bridge, 'EnforcedPause');
        });

        it('unpauses correctly', async function () {
            await bridge.pause();
            await bridge.unpause();

            const usdcIn = ethers.parseEther('4');
            const deadline = (await time.latest()) + 600;

            await usdc.connect(user1).approve(
                await bridge.getAddress(), usdcIn
            );

            // Should succeed
            await bridge.connect(user1).swap(
                await usdc.getAddress(),
                await xom.getAddress(),
                usdcIn,
                0,
                deadline
            );
        });

        it('only admin can pause/unpause', async function () {
            await expect(
                bridge.connect(user1).pause()
            ).to.be.reverted;

            await expect(
                bridge.connect(user1).unpause()
            ).to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                   EMERGENCY WITHDRAW
    // ═══════════════════════════════════════════════════════════════════

    describe('Emergency withdraw', function () {
        it('recovers tokens even beyond tracked reserves', async function () {
            // Send tokens directly (bypass deposit tracking)
            const amount = ethers.parseEther('5000');
            await xom.mint(await bridge.getAddress(), amount);

            // reserves[xom] = 0, but contract has 5000 XOM
            const before = await xom.balanceOf(user2.address);
            await bridge.emergencyWithdraw(
                await xom.getAddress(), amount, user2.address
            );
            const after = await xom.balanceOf(user2.address);

            expect(after - before).to.equal(amount);
            expect(await bridge.reserves(await xom.getAddress())).to.equal(0);
        });

        it('adjusts reserves downward when tracked', async function () {
            const deposit = ethers.parseEther('10000');
            await xom.connect(manager).approve(
                await bridge.getAddress(), deposit
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), deposit
            );

            const withdraw = ethers.parseEther('3000');
            await bridge.emergencyWithdraw(
                await xom.getAddress(), withdraw, user2.address
            );

            expect(await bridge.reserves(await xom.getAddress())).to.equal(
                deposit - withdraw
            );
        });

        it('only admin can call emergency withdraw', async function () {
            await expect(
                bridge.connect(user1).emergencyWithdraw(
                    await xom.getAddress(),
                    ethers.parseEther('100'),
                    user2.address
                )
            ).to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    getAmountOut
    // ═══════════════════════════════════════════════════════════════════

    describe('getAmountOut', function () {
        beforeEach(async function () {
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
        });

        it('returns correct amount for USDC → XOM', async function () {
            const usdcIn = ethers.parseEther('4');
            const expected = ethers.parseEther('1000');

            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                usdcIn
            );
            expect(out).to.equal(expected);
        });

        it('returns 0 for unsupported token', async function () {
            const fakeToken = ethers.Wallet.createRandom().address;
            const out = await bridge.getAmountOut(
                fakeToken,
                await xom.getAddress(),
                SWAP_AMOUNT
            );
            expect(out).to.equal(0);
        });

        it('returns 0 for zero amount', async function () {
            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                0
            );
            expect(out).to.equal(0);
        });

        it('returns 0 when exceeding maxSwapSize', async function () {
            const tooBig = MAX_SWAP_SIZE + 1n;
            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                tooBig
            );
            expect(out).to.equal(0);
        });

        it('returns 0 when reserves insufficient', async function () {
            // 600K USDC * 250 = 150M XOM > 125M reserve
            const tooMuch = ethers.parseEther('600000');
            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                tooMuch
            );
            expect(out).to.equal(0);
        });

        it('returns 0 when below minSwapSize', async function () {
            await bridge.connect(manager).setMinSwapSize(
                ethers.parseEther('100')
            );
            const out = await bridge.getAmountOut(
                await usdc.getAddress(),
                await xom.getAddress(),
                ethers.parseEther('50')
            );
            expect(out).to.equal(0);
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                   remainingDailyVolume
    // ═══════════════════════════════════════════════════════════════════

    describe('remainingDailyVolume', function () {
        it('returns max uint when no limit set', async function () {
            await bridge.connect(manager).setDailyVolumeLimit(0);
            const remaining = await bridge.remainingDailyVolume();
            expect(remaining).to.equal(ethers.MaxUint256);
        });

        it('returns full limit on fresh day', async function () {
            const limit = ethers.parseEther('1000');
            await bridge.connect(manager).setDailyVolumeLimit(limit);

            // Advance to next day to ensure fresh
            await time.increase(86401);

            const remaining = await bridge.remainingDailyVolume();
            expect(remaining).to.equal(limit);
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    RATE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    describe('Rate management', function () {
        it('emits RateUpdated event', async function () {
            const newRate = ethers.parseEther('300');
            await expect(
                bridge.connect(manager).setRate(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    newRate
                )
            )
                .to.emit(bridge, 'RateUpdated')
                .withArgs(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    RATE_USDC_TO_XOM,
                    newRate
                );
        });

        it('reverts on zero address in setRate', async function () {
            await expect(
                bridge.connect(manager).setRate(
                    ethers.ZeroAddress,
                    await xom.getAddress(),
                    1000
                )
            ).to.be.revertedWithCustomError(bridge, 'ZeroAddress');
        });

        it('returns 0 when no rate configured', async function () {
            // Remove rate for XOM → USDC
            await bridge.connect(manager).setRate(
                await xom.getAddress(),
                await usdc.getAddress(),
                0
            );

            // Deposit some XOM first
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );

            // getAmountOut returns 0 when no rate is configured
            const amountOut = await bridge.getAmountOut(
                await xom.getAddress(),
                await usdc.getAddress(),
                SWAP_AMOUNT
            );
            expect(amountOut).to.equal(0n);
        });

        it('reverts when rate exceeds MAX_RATE', async function () {
            const tooHigh = ethers.parseUnits('1', 41); // > 1e40
            await expect(
                bridge.connect(manager).setRate(
                    await xom.getAddress(),
                    await usdc.getAddress(),
                    tooHigh
                )
            ).to.be.revertedWithCustomError(bridge, 'RateTooHigh');
        });

        it('allows rate at exactly MAX_RATE', async function () {
            const maxRate = ethers.parseUnits('1', 40);
            await bridge.connect(manager).setRate(
                await xom.getAddress(),
                await usdc.getAddress(),
                maxRate
            );
            expect(
                await bridge.directRate(
                    await xom.getAddress(),
                    await usdc.getAddress()
                )
            ).to.equal(maxRate);
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    SAFE SET RATE
    // ═══════════════════════════════════════════════════════════════════

    describe('safeSetRate', function () {
        it('atomically pauses and unpauses during rate change',
            async function () {
                // Before: not paused
                expect(await bridge.paused()).to.be.false;

                const newRate = ethers.parseEther('300');
                await bridge.connect(manager).safeSetRate(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    newRate
                );

                // After: rate changed, still unpaused
                expect(await bridge.paused()).to.be.false;
                expect(
                    await bridge.directRate(
                        await usdc.getAddress(),
                        await xom.getAddress()
                    )
                ).to.equal(newRate);
            }
        );

        it('emits RateUpdated event', async function () {
            const newRate = ethers.parseEther('500');
            await expect(
                bridge.connect(manager).safeSetRate(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    newRate
                )
            )
                .to.emit(bridge, 'RateUpdated')
                .withArgs(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    RATE_USDC_TO_XOM,
                    newRate
                );
        });

        it('leaves contract paused if already paused', async function () {
            // Pause first
            await bridge.pause();
            expect(await bridge.paused()).to.be.true;

            // safeSetRate while already paused
            const newRate = ethers.parseEther('500');
            await bridge.connect(manager).safeSetRate(
                await usdc.getAddress(),
                await xom.getAddress(),
                newRate
            );

            // Should still be paused
            expect(await bridge.paused()).to.be.true;
            expect(
                await bridge.directRate(
                    await usdc.getAddress(),
                    await xom.getAddress()
                )
            ).to.equal(newRate);
        });

        it('reverts on MAX_RATE exceeded', async function () {
            const tooHigh = ethers.parseUnits('1', 41);
            await expect(
                bridge.connect(manager).safeSetRate(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    tooHigh
                )
            ).to.be.revertedWithCustomError(bridge, 'RateTooHigh');
        });

        it('reverts for non-manager', async function () {
            await expect(
                bridge.connect(user1).safeSetRate(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    ethers.parseEther('100')
                )
            ).to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //                    ORACLE DEVIATION LIMITS
    // ═══════════════════════════════════════════════════════════════════

    describe('Oracle deviation limits', function () {
        it('sets and emits maxOracleDeviationBps', async function () {
            await expect(
                bridge.connect(manager).setMaxOracleDeviationBps(500)
            )
                .to.emit(bridge, 'MaxOracleDeviationBpsUpdated')
                .withArgs(0n, 500n);

            expect(await bridge.maxOracleDeviationBps()).to.equal(500n);
        });

        it('reverts when bps exceeds MAX_BPS', async function () {
            await expect(
                bridge.connect(manager).setMaxOracleDeviationBps(10001)
            ).to.be.revertedWithCustomError(
                bridge, 'VolumeLimitTooHigh'
            );
        });

        it('allows bps at exactly MAX_BPS', async function () {
            await bridge.connect(manager).setMaxOracleDeviationBps(10000);
            expect(await bridge.maxOracleDeviationBps()).to.equal(10000n);
        });

        it('reverts for non-manager', async function () {
            await expect(
                bridge.connect(user1).setMaxOracleDeviationBps(500)
            ).to.be.reverted;
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //              COMPLETE BOOTSTRAPPING FLOW
    // ═══════════════════════════════════════════════════════════════════

    describe('Full bootstrapping flow', function () {
        it('simulates deployer selling XOM for USDC from LP providers',
            async function () {
                // 1. Manager deposits 125M XOM
                await xom.connect(manager).approve(
                    await bridge.getAddress(), DEPOSIT_XOM
                );
                await bridge.connect(manager).deposit(
                    await xom.getAddress(), DEPOSIT_XOM
                );

                // 2. LP provider swaps 400 USDC → XOM (gets 100K XOM)
                const usdcIn = ethers.parseEther('400');
                const expectedXOM = ethers.parseEther('100000');
                const deadline = (await time.latest()) + 600;

                await usdc.connect(user1).approve(
                    await bridge.getAddress(), usdcIn
                );
                await bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    usdcIn,
                    expectedXOM,
                    deadline
                );

                // 3. Verify user got XOM
                expect(
                    await xom.balanceOf(user1.address)
                ).to.equal(SEED_AMOUNT + expectedXOM);

                // 4. Verify bridge accumulated USDC
                expect(
                    await bridge.reserves(await usdc.getAddress())
                ).to.equal(usdcIn);

                // 5. Manager withdraws accumulated USDC
                await bridge.connect(manager).withdraw(
                    await usdc.getAddress(),
                    usdcIn,
                    manager.address
                );
                expect(
                    await bridge.reserves(await usdc.getAddress())
                ).to.equal(0);

                // 6. XOM reserves decreased
                expect(
                    await bridge.reserves(await xom.getAddress())
                ).to.equal(DEPOSIT_XOM - expectedXOM);
            }
        );
    });

    // ═══════════════════════════════════════════════════════════════════
    //              PRODUCTION HARDENING INTEGRATION
    // ═══════════════════════════════════════════════════════════════════

    describe('Production hardening (combined features)', function () {
        beforeEach(async function () {
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );
            await usdc.mint(user2.address, SEED_AMOUNT);
        });

        it('min + max + per-user + global all enforced together',
            async function () {
                // Configure all limits
                await bridge.connect(manager).setMinSwapSize(
                    ethers.parseEther('10')
                );
                await bridge.connect(manager).setMaxSwapSize(
                    ethers.parseEther('5000')
                );
                await bridge.connect(manager).setDailyVolumeLimit(
                    ethers.parseEther('8000')
                );
                await bridge.connect(manager).setPerUserDailyVolumeLimit(
                    ethers.parseEther('3000')
                );

                const deadline = (await time.latest()) + 600;

                // Too small (< 10)
                await usdc.connect(user1).approve(
                    await bridge.getAddress(),
                    ethers.parseEther('100000')
                );
                await expect(
                    bridge.connect(user1).swap(
                        await usdc.getAddress(),
                        await xom.getAddress(),
                        ethers.parseEther('5'), // Below min
                        0,
                        deadline
                    )
                ).to.be.revertedWithCustomError(bridge, 'SwapTooSmall');

                // Too large (> 5000)
                await expect(
                    bridge.connect(user1).swap(
                        await usdc.getAddress(),
                        await xom.getAddress(),
                        ethers.parseEther('6000'), // Above max
                        0,
                        deadline
                    )
                ).to.be.revertedWithCustomError(bridge, 'SwapTooLarge');

                // First swap OK: 2500
                await bridge.connect(user1).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    ethers.parseEther('2500'),
                    0,
                    deadline
                );

                // Second swap exceeds per-user limit (2500+2500 > 3000)
                await expect(
                    bridge.connect(user1).swap(
                        await usdc.getAddress(),
                        await xom.getAddress(),
                        ethers.parseEther('2500'),
                        0,
                        deadline + 600
                    )
                ).to.be.revertedWithCustomError(
                    bridge, 'UserDailyVolumeLimitExceeded'
                );

                // User2 can still swap (separate per-user counter)
                await usdc.connect(user2).approve(
                    await bridge.getAddress(),
                    ethers.parseEther('3000')
                );
                await bridge.connect(user2).swap(
                    await usdc.getAddress(),
                    await xom.getAddress(),
                    ethers.parseEther('3000'),
                    0,
                    deadline
                );

                // Global volume = 2500 + 3000 = 5500, within 8000 limit
                expect(await bridge.dailyVolumeUsed()).to.equal(
                    ethers.parseEther('5500')
                );
            }
        );
    });

    // ═══════════════════════════════════════════════════════════════════
    //         6-DECIMAL USDC PRODUCTION PATH (#19 / #23)
    // ═══════════════════════════════════════════════════════════════════
    //
    // Every mock above is an 18-decimal token, so the real USDC path — a
    // 6-decimal input with the production 1e12 volumeNormalizer and a
    // cross-decimal rate — was never exercised. This block wires a genuine
    // 6-decimal TestUSDC (decimals() == 6) and asserts BOTH amountOut and the
    // normalized daily-volume accounting are correct across both directions.
    describe('6-decimal USDC production path (#19/#23)', function () {
        let usdc6: any;

        // Cross-decimal rates (see contract setRate NatSpec, lines 623-629):
        //   USDC(6) -> XOM(18) at $0.004: 1e6 USDC -> 250e18 XOM => 250e30
        //   XOM(18) -> USDC(6) at $0.004: 1e18 XOM -> 4000 USDC-wei => 4000
        const RATE_USDC6_TO_XOM = 250n * 10n ** 30n;
        const RATE_XOM_TO_USDC6 = 4000n;
        // Production normalizer for a 6-decimal token: amount * 1e12 -> 18-dec.
        const USDC6_NORMALIZER = 10n ** 12n;

        beforeEach(async function () {
            // Confirm the mock really is 6 decimals (guards the whole point).
            const TestUSDC = await ethers.getContractFactory('TestUSDC');
            usdc6 = await TestUSDC.deploy();
            expect(await usdc6.decimals()).to.equal(6);

            // Whitelist + configure the 6-decimal token.
            await bridge.setSupportedToken(await usdc6.getAddress(), true);
            await bridge.connect(manager).setRate(
                await usdc6.getAddress(),
                await xom.getAddress(),
                RATE_USDC6_TO_XOM
            );
            await bridge.connect(manager).setRate(
                await xom.getAddress(),
                await usdc6.getAddress(),
                RATE_XOM_TO_USDC6
            );
            await bridge.connect(manager).setVolumeNormalizer(
                await usdc6.getAddress(),
                USDC6_NORMALIZER
            );

            // Seed XOM reserves for USDC->XOM, and USDC6 reserves for XOM->USDC.
            await xom.connect(manager).approve(
                await bridge.getAddress(), DEPOSIT_XOM
            );
            await bridge.connect(manager).deposit(
                await xom.getAddress(), DEPOSIT_XOM
            );

            // owner holds TestUSDC constructor supply (100M * 1e6); seed the
            // bridge USDC reserves + fund user1 without the mint() cooldown.
            const usdcReserve = 1_000_000n * 10n ** 6n; // 1,000,000 USDC
            await usdc6.ownerMint(manager.address, usdcReserve);
            await usdc6.connect(manager).approve(
                await bridge.getAddress(), usdcReserve
            );
            await bridge.connect(manager).deposit(
                await usdc6.getAddress(), usdcReserve
            );

            await usdc6.ownerMint(user1.address, 100_000n * 10n ** 6n);
        });

        it('swaps 6-dec USDC -> 18-dec XOM with correct amountOut', async function () {
            const usdcIn = 4n * 10n ** 6n;          // 4 USDC (6 dec)
            const expectedXOM = ethers.parseEther('1000'); // 4 * 250 = 1000 XOM
            const deadline = (await time.latest()) + 600;

            await usdc6.connect(user1).approve(
                await bridge.getAddress(), usdcIn
            );

            const before = await xom.balanceOf(user1.address);
            await bridge.connect(user1).swap(
                await usdc6.getAddress(),
                await xom.getAddress(),
                usdcIn,
                expectedXOM,
                deadline
            );
            const after = await xom.balanceOf(user1.address);

            // amountOut = usdcIn(1e6-scale) * 250e30 / 1e18 = 1000e18.
            expect(after - before).to.equal(expectedXOM);

            // Daily volume must count the NORMALIZED (18-dec-equivalent) input:
            // 4 USDC -> 4e6 * 1e12 = 4e18, NOT the raw 4e6.
            expect(await bridge.dailyVolumeUsed()).to.equal(
                ethers.parseEther('4')
            );
        });

        it('swaps 18-dec XOM -> 6-dec USDC with correct amountOut', async function () {
            const xomIn = ethers.parseEther('1000');   // 1000 XOM
            const expectedUSDC = 4n * 10n ** 6n;        // 4 USDC (6 dec)
            const deadline = (await time.latest()) + 600;

            await xom.connect(user1).approve(
                await bridge.getAddress(), xomIn
            );

            const before = await usdc6.balanceOf(user1.address);
            await bridge.connect(user1).swap(
                await xom.getAddress(),
                await usdc6.getAddress(),
                xomIn,
                expectedUSDC,
                deadline
            );
            const after = await usdc6.balanceOf(user1.address);

            // amountOut = 1000e18 * 4000 / 1e18 = 4,000,000 = 4 USDC (6 dec).
            expect(after - before).to.equal(expectedUSDC);

            // XOM has no normalizer (18-dec): daily volume counts raw 1000e18.
            expect(await bridge.dailyVolumeUsed()).to.equal(
                ethers.parseEther('1000')
            );
        });
    });
});
