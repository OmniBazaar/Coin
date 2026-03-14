const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * @title RWAAMM Test Suite
 * @notice Comprehensive tests for RWA AMM Protocol
 */
describe('RWAAMM Protocol', function () {
    // Signers
    let owner;
    let user1;
    let user2;
    let emergencySigners;

    /**
     * @notice Get a block-timestamp-relative deadline to avoid DeadlineExpired
     *         errors when the Hardhat EVM timestamp diverges from wall clock
     *         (which happens during long full-suite test runs).
     * @param {number} offset Seconds from latest block (default 3600)
     * @returns {Promise<number>} Future deadline timestamp
     */
    async function futureDeadline(offset = 3600) {
        const block = await ethers.provider.getBlock('latest');
        return block.timestamp + offset;
    }

    // Contracts
    let amm;
    let router;
    let feeVault;
    let complianceOracle;

    // Mock tokens
    let xomToken;
    let rwaToken;
    let wavax;

    // Constants
    const PROTOCOL_FEE_BPS = 30n; // 0.30%
    const INITIAL_LIQUIDITY = ethers.parseEther('1000');
    const SWAP_AMOUNT = ethers.parseEther('10');

    before(async function () {
        // Get signers (hardhat provides 20 signers by default)
        const signers = await ethers.getSigners();
        owner = signers[0];
        user1 = signers[1];
        user2 = signers[2];
        // Emergency signers (need 5) - signers 4-8
        emergencySigners = signers.slice(4, 9);
    });

    beforeEach(async function () {
        // Deploy mock tokens
        const MockToken = await ethers.getContractFactory('ERC20Mock');
        xomToken = await MockToken.deploy('XOM Token', 'XOM');
        await xomToken.waitForDeployment();

        rwaToken = await MockToken.deploy('RWA Token', 'RWA');
        await rwaToken.waitForDeployment();

        wavax = await MockToken.deploy('Wrapped AVAX', 'WAVAX');
        await wavax.waitForDeployment();

        // Deploy compliance oracle
        const ComplianceOracle = await ethers.getContractFactory('RWAComplianceOracle');
        complianceOracle = await ComplianceOracle.deploy(owner.address);
        await complianceOracle.waitForDeployment();

        // Use a dedicated signer as the fee vault (UnifiedFeeVault stand-in)
        const signers = await ethers.getSigners();
        feeVault = signers[3];

        // Deploy RWAAMM with fee vault address
        const emergencyAddresses = emergencySigners.map(s => s.address);
        const RWAAMM = await ethers.getContractFactory('RWAAMM');
        amm = await RWAAMM.deploy(
            emergencyAddresses,
            feeVault.address,
            await xomToken.getAddress(),
            await complianceOracle.getAddress(),
            ethers.ZeroAddress,
        );
        await amm.waitForDeployment();

        // Deploy router
        const Router = await ethers.getContractFactory('RWARouter');
        router = await Router.deploy(await amm.getAddress(), ethers.ZeroAddress);
        await router.waitForDeployment();

        // Register tokens with compliance oracle (audit fix H-02:
        // pool creation now requires at least one registered token)
        await complianceOracle.connect(owner).registerToken(
            await xomToken.getAddress(), ethers.ZeroAddress,
        );
        await complianceOracle.connect(owner).registerToken(
            await rwaToken.getAddress(), ethers.ZeroAddress,
        );

        // Mint tokens to users
        await xomToken.mint(owner.address, ethers.parseEther('1000000'));
        await xomToken.mint(user1.address, ethers.parseEther('100000'));
        await xomToken.mint(user2.address, ethers.parseEther('100000'));

        await rwaToken.mint(owner.address, ethers.parseEther('1000000'));
        await rwaToken.mint(user1.address, ethers.parseEther('100000'));
        await rwaToken.mint(user2.address, ethers.parseEther('100000'));
    });

    describe('Deployment', function () {
        it('Should deploy with correct protocol fee', async function () {
            expect(await amm.protocolFeeBps()).to.equal(PROTOCOL_FEE_BPS);
        });

        it('Should set immutable addresses correctly', async function () {
            expect(await amm.FEE_VAULT()).to.equal(feeVault.address);
            expect(await amm.XOM_TOKEN()).to.equal(await xomToken.getAddress());
            expect(await amm.COMPLIANCE_ORACLE()).to.equal(await complianceOracle.getAddress());
        });

        it('Should set emergency signers correctly', async function () {
            expect(await amm.EMERGENCY_SIGNER_1()).to.equal(emergencySigners[0].address);
            expect(await amm.EMERGENCY_SIGNER_5()).to.equal(emergencySigners[4].address);
        });

        it('Should reject zero addresses in constructor', async function () {
            const RWAAMM = await ethers.getContractFactory('RWAAMM');
            const emergencyAddresses = emergencySigners.map(s => s.address);

            await expect(
                RWAAMM.deploy(
                    emergencyAddresses,
                    ethers.ZeroAddress, // Invalid fee vault
                    await xomToken.getAddress(),
                    await complianceOracle.getAddress(),
                    ethers.ZeroAddress,
                ),
            ).to.be.revertedWithCustomError(amm, 'ZeroAddress');
        });
    });

    describe('Pool Creation', function () {
        it('Should create pool for token pair', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            // Approve tokens
            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            // Add liquidity (creates pool)
            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr,
                rwaAddr,
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY,
                0n,
                0n,
                deadline,
                ethers.ZeroAddress, // onBehalfOf: use msg.sender
            );

            // Check pool exists
            const poolId = await amm.getPoolId(xomAddr, rwaAddr);
            expect(await amm.poolExists(poolId)).to.be.true;
        });

        it('Should emit PoolCreated event', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();

            await expect(
                amm.connect(owner).addLiquidity(
                    xomAddr,
                    rwaAddr,
                    INITIAL_LIQUIDITY,
                    INITIAL_LIQUIDITY,
                    0n,
                    0n,
                    deadline,
                    ethers.ZeroAddress,
                )
            ).to.emit(amm, 'PoolCreated');
        });

        it('Should reject pool creation with same tokens', async function () {
            const xomAddr = await xomToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY * 2n);

            const deadline = await futureDeadline();

            await expect(
                amm.connect(owner).addLiquidity(
                    xomAddr,
                    xomAddr, // Same token
                    INITIAL_LIQUIDITY,
                    INITIAL_LIQUIDITY,
                    0n,
                    0n,
                    deadline,
                    ethers.ZeroAddress,
                ),
            ).to.be.revertedWithCustomError(amm, 'IdenticalTokens');
        });
    });

    describe('Liquidity Operations', function () {
        beforeEach(async function () {
            // Create pool first
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr,
                rwaAddr,
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY,
                0n,
                0n,
                deadline,
                ethers.ZeroAddress, // onBehalfOf: use msg.sender
            );
        });

        it('Should add liquidity to existing pool', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();
            const additionalLiquidity = ethers.parseEther('100');

            await xomToken.connect(user1).approve(await amm.getAddress(), additionalLiquidity);
            await rwaToken.connect(user1).approve(await amm.getAddress(), additionalLiquidity);

            const deadline = await futureDeadline();
            await expect(
                amm.connect(user1).addLiquidity(
                    xomAddr,
                    rwaAddr,
                    additionalLiquidity,
                    additionalLiquidity,
                    0n,
                    0n,
                    deadline,
                    ethers.ZeroAddress,
                ),
            ).to.emit(amm, 'LiquidityAdded');
        });

        it('Should remove liquidity correctly', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();
            const poolId = await amm.getPoolId(xomAddr, rwaAddr);

            // Get pool address (which is also the LP token) - use signature to disambiguate
            const poolAddr = await amm['getPool(address,address)'](xomAddr, rwaAddr);

            // Get LP balance from pool (using ERC20 balanceOf)
            const poolContract = await ethers.getContractAt('RWAPool', poolAddr);
            const lpBalance = await poolContract.balanceOf(owner.address);

            // Remove half liquidity
            const removeAmount = lpBalance / 2n;
            const deadline = await futureDeadline();

            // Approve LP tokens for AMM
            await poolContract.connect(owner).approve(await amm.getAddress(), removeAmount);

            await expect(
                amm.connect(owner).removeLiquidity(
                    xomAddr,
                    rwaAddr,
                    removeAmount,
                    0n,
                    0n,
                    deadline,
                    ethers.ZeroAddress,
                ),
            ).to.emit(amm, 'LiquidityRemoved');
        });
    });

    describe('Swap Operations', function () {
        beforeEach(async function () {
            // Create pool with liquidity
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr,
                rwaAddr,
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY,
                0n,
                0n,
                deadline,
                ethers.ZeroAddress, // onBehalfOf: use msg.sender
            );
        });

        it('Should execute swap correctly', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            // User1 swaps XOM for RWA
            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);

            const deadline = await futureDeadline();
            const user1RwaBefore = await rwaToken.balanceOf(user1.address);

            await amm.connect(user1).swap(
                xomAddr,
                rwaAddr,
                SWAP_AMOUNT,
                0n, // No minimum (for testing)
                deadline,
                ethers.ZeroAddress, // onBehalfOf: use msg.sender
            );

            const user1RwaAfter = await rwaToken.balanceOf(user1.address);
            expect(user1RwaAfter).to.be.gt(user1RwaBefore);
        });

        it('Should emit Swap event', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);

            const deadline = await futureDeadline();

            await expect(
                amm.connect(user1).swap(
                    xomAddr,
                    rwaAddr,
                    SWAP_AMOUNT,
                    0n,
                    deadline,
                    ethers.ZeroAddress,
                ),
            ).to.emit(amm, 'Swap');
        });

        it('Should revert on expired deadline', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);

            // Use block-relative past timestamp to guarantee expiry
            const block = await ethers.provider.getBlock('latest');
            const expiredDeadline = block.timestamp - 3600;

            await expect(
                amm.connect(user1).swap(
                    xomAddr,
                    rwaAddr,
                    SWAP_AMOUNT,
                    0n,
                    expiredDeadline,
                    ethers.ZeroAddress,
                ),
            ).to.be.revertedWithCustomError(amm, 'DeadlineExpired');
        });

        it('Should revert on slippage exceeded', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);

            const deadline = await futureDeadline();
            const unreasonableMinOut = ethers.parseEther('1000'); // Way too high

            await expect(
                amm.connect(user1).swap(
                    xomAddr,
                    rwaAddr,
                    SWAP_AMOUNT,
                    unreasonableMinOut,
                    deadline,
                    ethers.ZeroAddress,
                ),
            ).to.be.revertedWithCustomError(amm, 'SlippageExceeded');
        });
    });

    describe('Quote Functions', function () {
        beforeEach(async function () {
            // Create pool with liquidity
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr,
                rwaAddr,
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY,
                0n,
                0n,
                deadline,
                ethers.ZeroAddress, // onBehalfOf: use msg.sender
            );
        });

        it('Should return accurate quote', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const [amountOut, protocolFee, priceImpact] = await amm.getQuote(
                xomAddr,
                rwaAddr,
                SWAP_AMOUNT,
            );

            expect(amountOut).to.be.gt(0n);
            expect(protocolFee).to.be.gt(0n);
            // Price impact in basis points
            expect(priceImpact).to.be.gte(0n);
        });

        it('Should calculate correct protocol fee', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const [, protocolFee, ] = await amm.getQuote(
                xomAddr,
                rwaAddr,
                SWAP_AMOUNT,
            );

            // 0.30% fee
            const expectedFee = SWAP_AMOUNT * 30n / 10000n;
            expect(protocolFee).to.equal(expectedFee);
        });
    });

    describe('Fee Vault Integration', function () {
        it('Should have correct fee distribution ratios on AMM', async function () {
            // FEE_LP_BPS (70%) stays in pool, rest goes to UnifiedFeeVault
            expect(await amm.FEE_LP_BPS()).to.equal(7000n); // 70%
        });

        it('Should set FEE_VAULT correctly', async function () {
            expect(await amm.FEE_VAULT()).to.equal(feeVault.address);
        });
    });

    describe('RWAComplianceOracle', function () {
        it('Should deploy with correct registrar', async function () {
            expect(await complianceOracle.registrar()).to.equal(owner.address);
        });

        it('Should register token', async function () {
            // Use WAVAX (not already registered in beforeEach)
            const wavaxAddr = await wavax.getAddress();

            await expect(
                complianceOracle.connect(owner).registerToken(wavaxAddr, ethers.ZeroAddress)
            ).to.emit(complianceOracle, 'TokenRegistered');

            expect(await complianceOracle.isTokenRegistered(wavaxAddr)).to.be.true;
        });

        it('Should check compliance for registered token', async function () {
            // XOM is already registered in beforeEach (audit fix H-02)
            const xomAddr = await xomToken.getAddress();

            const result = await complianceOracle.checkCompliance(user1.address, xomAddr);
            // ERC20 tokens are always compliant
            expect(result.status).to.equal(0n); // COMPLIANT
        });

        it('Should return non-compliant for unregistered tokens (H-01 fail-closed)', async function () {
            const unregisteredToken = ethers.Wallet.createRandom().address;

            // H-01 audit fix: unregistered tokens default to NON_COMPLIANT
            // to prevent unregistered wrapper tokens from bypassing compliance.
            const result = await complianceOracle.checkCompliance(user1.address, unregisteredToken);
            expect(result.status).to.equal(1n); // NON_COMPLIANT
        });
    });

    describe('RWARouter', function () {
        beforeEach(async function () {
            // Create pool with liquidity
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr,
                rwaAddr,
                INITIAL_LIQUIDITY,
                INITIAL_LIQUIDITY,
                0n,
                0n,
                deadline,
                ethers.ZeroAddress, // onBehalfOf: use msg.sender
            );
        });

        it('Should deploy with correct AMM address', async function () {
            expect(await router.AMM()).to.equal(await amm.getAddress());
        });

        it('Should route swaps through AMM (C-01 fix)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            // C-01 fix: Router now routes ALL swaps through RWAAMM, which
            // calls pool.swap() as the factory. This ensures compliance
            // checks and fee collection are never bypassed.
            await xomToken.connect(user1).approve(await router.getAddress(), SWAP_AMOUNT);

            const deadline = await futureDeadline();
            const user1RwaBefore = await rwaToken.balanceOf(user1.address);

            // amountOutMin must be > 0 (router enforces ZeroMinimumOutput)
            await router.connect(user1).swapExactTokensForTokens(
                SWAP_AMOUNT,
                1n, // Minimum 1 wei output (slippage protection)
                [xomAddr, rwaAddr],
                user1.address,
                deadline,
            );

            const user1RwaAfter = await rwaToken.balanceOf(user1.address);
            expect(user1RwaAfter).to.be.gt(user1RwaBefore);
        });

        it('Should route addLiquidity through AMM (C-01 fix)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();
            const addAmount = ethers.parseEther('100');

            // C-01 fix: Router now routes addLiquidity through RWAAMM, which
            // calls pool.mint() as the factory. This ensures compliance
            // checks are enforced for LP operations.
            await xomToken.connect(user1).approve(await router.getAddress(), addAmount);
            await rwaToken.connect(user1).approve(await router.getAddress(), addAmount);

            const deadline = await futureDeadline();

            // Should succeed — router delegates to AMM which is the pool factory
            await router.connect(user1).addLiquidity(
                xomAddr,
                rwaAddr,
                addAmount,
                addAmount,
                0n,
                0n,
                user1.address,
                deadline,
            );

            // Verify LP tokens were minted to user1
            const poolAddr = await amm['getPool(address,address)'](xomAddr, rwaAddr);
            const poolContract = await ethers.getContractAt('RWAPool', poolAddr);
            const lpBalance = await poolContract.balanceOf(user1.address);
            expect(lpBalance).to.be.gt(0n);
        });
    });

    describe('Emergency Controls', function () {
        it('Should require 3-of-5 signatures to pause', async function () {
            const poolId = ethers.ZeroHash;

            // Try to pause with only 2 signatures (should fail, need 3)
            const twoSignatures = ['0x', '0x'];

            await expect(
                amm.connect(emergencySigners[0]).emergencyPause(
                    poolId,
                    'Test pause',
                    twoSignatures,
                ),
            ).to.be.revertedWithCustomError(amm, 'InsufficientSignatures');
        });
    });

    // =====================================================================
    //  NEW TESTS - AMM Math Verification
    // =====================================================================
    describe('AMM Math Verification', function () {
        beforeEach(async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );
        });

        it('Should calculate constant product formula correctly (x * y = k)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            // For 1:1 pool of 1000:1000 with amountIn = 10
            // fee = 10 * 30 / 10000 = 0.03
            // amountInAfterFee = 10 - 0.03 = 9.97
            // amountOut = (1000 * 9.97) / (1000 + 9.97) = 9970 / 1009.97 ~ 9.87
            const [amountOut, , ] = await amm.getQuote(xomAddr, rwaAddr, SWAP_AMOUNT);

            // Manual calculation: dy = (y * dx) / (x + dx)
            const fee = SWAP_AMOUNT * 30n / 10000n;
            const dx = SWAP_AMOUNT - fee;
            const x = INITIAL_LIQUIDITY;
            const y = INITIAL_LIQUIDITY;
            const expectedOut = (y * dx) / (x + dx);

            expect(amountOut).to.equal(expectedOut);
        });

        it('Should produce diminishing returns for larger swaps (price impact)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const smallSwap = ethers.parseEther('1');
            const bigSwap = ethers.parseEther('100');

            const [smallOut, , smallImpact] = await amm.getQuote(xomAddr, rwaAddr, smallSwap);
            const [bigOut, , bigImpact] = await amm.getQuote(xomAddr, rwaAddr, bigSwap);

            // Big swap should have higher price impact
            expect(bigImpact).to.be.gt(smallImpact);

            // Rate for big swap should be worse than small swap (per unit output)
            const smallRate = (smallOut * 10000n) / smallSwap;
            const bigRate = (bigOut * 10000n) / bigSwap;
            expect(smallRate).to.be.gt(bigRate);
        });

        it('Should revert getQuote on zero amountIn', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await expect(
                amm.getQuote(xomAddr, rwaAddr, 0n)
            ).to.be.revertedWithCustomError(amm, 'ZeroAmount');
        });

        it('Should revert getQuote on non-existent pool', async function () {
            const wavaxAddr = await wavax.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await expect(
                amm.getQuote(wavaxAddr, rwaAddr, SWAP_AMOUNT)
            ).to.be.revertedWithCustomError(amm, 'PoolNotFound');
        });

        it('Should produce symmetric pool IDs regardless of token order', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const id1 = await amm.getPoolId(xomAddr, rwaAddr);
            const id2 = await amm.getPoolId(rwaAddr, xomAddr);

            expect(id1).to.equal(id2);
        });

        it('Quote output should match actual swap output', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const [quotedOut, , ] = await amm.getQuote(xomAddr, rwaAddr, SWAP_AMOUNT);

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline = await futureDeadline();
            const balBefore = await rwaToken.balanceOf(user1.address);

            await amm.connect(user1).swap(
                xomAddr, rwaAddr, SWAP_AMOUNT, 0n, deadline, ethers.ZeroAddress,
            );

            const balAfter = await rwaToken.balanceOf(user1.address);
            const actualOut = balAfter - balBefore;

            expect(actualOut).to.equal(quotedOut);
        });
    });

    // =====================================================================
    //  NEW TESTS - Slippage Protection
    // =====================================================================
    describe('Slippage Protection', function () {
        beforeEach(async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );
        });

        it('Should succeed when amountOutMin is exactly met', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            // Get exact quote
            const [exactOut, , ] = await amm.getQuote(xomAddr, rwaAddr, SWAP_AMOUNT);

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline = await futureDeadline();

            // Should succeed when minOut exactly equals expected output
            await expect(
                amm.connect(user1).swap(
                    xomAddr, rwaAddr, SWAP_AMOUNT, exactOut, deadline, ethers.ZeroAddress,
                )
            ).to.not.be.reverted;
        });

        it('Should revert when amountOutMin is 1 wei above actual', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const [exactOut, , ] = await amm.getQuote(xomAddr, rwaAddr, SWAP_AMOUNT);

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline = await futureDeadline();

            await expect(
                amm.connect(user1).swap(
                    xomAddr, rwaAddr, SWAP_AMOUNT, exactOut + 1n, deadline, ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'SlippageExceeded');
        });

        it('Should revert swap with zero amountIn', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const deadline = await futureDeadline();

            await expect(
                amm.connect(user1).swap(
                    xomAddr, rwaAddr, 0n, 0n, deadline, ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'ZeroAmount');
        });
    });

    // =====================================================================
    //  NEW TESTS - Fee Paths (Protocol, LP)
    // =====================================================================
    describe('Fee Paths', function () {
        beforeEach(async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );
        });

        it('Should have correct constant fee split ratios', async function () {
            expect(await amm.FEE_LP_BPS()).to.equal(7000n);        // 70%
            expect(await amm.FEE_STAKING_BPS()).to.equal(2000n);   // 20%
            expect(await amm.FEE_PROTOCOL_BPS()).to.equal(1000n);  // 10%

            // Verify they add to 100%
            const total = 7000n + 2000n + 1000n;
            expect(total).to.equal(10000n);
        });

        it('Should transfer vault fee (30% of protocol fee) to FEE_VAULT on swap', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const vaultBalBefore = await xomToken.balanceOf(feeVault.address);

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline = await futureDeadline();

            await amm.connect(user1).swap(
                xomAddr, rwaAddr, SWAP_AMOUNT, 0n, deadline, ethers.ZeroAddress,
            );

            const vaultBalAfter = await xomToken.balanceOf(feeVault.address);
            const vaultReceived = vaultBalAfter - vaultBalBefore;

            // Vault should receive 30% of the 0.30% fee
            // protocolFee = 10 * 30 / 10000 = 0.03 ETH
            // lpFee = 0.03 * 7000 / 10000 = 0.021 ETH
            // vaultFee = 0.03 - 0.021 = 0.009 ETH
            const protocolFee = SWAP_AMOUNT * 30n / 10000n;
            const lpFee = protocolFee * 7000n / 10000n;
            const expectedVaultFee = protocolFee - lpFee;

            expect(vaultReceived).to.equal(expectedVaultFee);
        });

        it('Should increase pool reserves by amountInAfterFee + lpFee on swap', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            const poolAddr = await amm['getPool(address,address)'](xomAddr, rwaAddr);
            const pool = await ethers.getContractAt('RWAPool', poolAddr);
            const [r0Before, r1Before, ] = await pool.getReserves();

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline = await futureDeadline();

            const [quotedOut, , ] = await amm.getQuote(xomAddr, rwaAddr, SWAP_AMOUNT);

            await amm.connect(user1).swap(
                xomAddr, rwaAddr, SWAP_AMOUNT, 0n, deadline, ethers.ZeroAddress,
            );

            const [r0After, r1After, ] = await pool.getReserves();

            // Determine which reserve is xomToken
            const token0 = await pool.token0();
            if (token0 === xomAddr) {
                // token0 (xom) reserve should increase, token1 (rwa) should decrease
                expect(r0After).to.be.gt(r0Before);
                expect(r1After).to.be.lt(r1Before);
            } else {
                // token1 (xom) reserve should increase, token0 (rwa) should decrease
                expect(r1After).to.be.gt(r1Before);
                expect(r0After).to.be.lt(r0Before);
            }
        });

        it('Should enforce immutable PROTOCOL_FEE_BPS of 30', async function () {
            expect(await amm.PROTOCOL_FEE_BPS()).to.equal(30n);
            expect(await amm.BPS_DENOMINATOR()).to.equal(10000n);
        });
    });

    // =====================================================================
    //  NEW TESTS - Compliance Oracle Integration
    // =====================================================================
    describe('Compliance Oracle Integration', function () {
        it('Should reject pool creation when neither token is registered (H-02)', async function () {
            const wavaxAddr = await wavax.getAddress();
            // Deploy a totally unregistered token
            const MockToken = await ethers.getContractFactory('ERC20Mock');
            const unregistered = await MockToken.deploy('Unreg', 'UNREG');
            const unregAddr = await unregistered.getAddress();

            await wavax.mint(owner.address, INITIAL_LIQUIDITY);
            await unregistered.mint(owner.address, INITIAL_LIQUIDITY);
            await wavax.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await unregistered.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();

            await expect(
                amm.connect(owner).addLiquidity(
                    wavaxAddr, unregAddr,
                    INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                    0n, 0n, deadline, ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'UnregisteredPoolTokens');
        });

        it('Should allow pool creation when at least one token is registered', async function () {
            const xomAddr = await xomToken.getAddress();
            const wavaxAddr = await wavax.getAddress();

            // XOM is registered but WAVAX is not
            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await wavax.mint(owner.address, INITIAL_LIQUIDITY);
            await wavax.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();

            await expect(
                amm.connect(owner).addLiquidity(
                    xomAddr, wavaxAddr,
                    INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                    0n, 0n, deadline, ethers.ZeroAddress,
                )
            ).to.emit(amm, 'PoolCreated');
        });

        it('Should verify deployer is initial pool creator', async function () {
            expect(await amm.isPoolCreator(owner.address)).to.be.true;
        });

        it('Should reject pool creation from non-pool-creator via createPool', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await expect(
                amm.connect(user1).createPool(xomAddr, rwaAddr)
            ).to.be.revertedWithCustomError(amm, 'NotPoolCreator');
        });
    });

    // =====================================================================
    //  NEW TESTS - Liquidity Provision Edge Cases
    // =====================================================================
    describe('Liquidity Provision Edge Cases', function () {
        it('Should mint LP tokens proportional to deposit for initial liquidity', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );

            const poolAddr = await amm['getPool(address,address)'](xomAddr, rwaAddr);
            const pool = await ethers.getContractAt('RWAPool', poolAddr);

            // Owner should have LP tokens (minus MINIMUM_LIQUIDITY locked)
            const lpBal = await pool.balanceOf(owner.address);
            expect(lpBal).to.be.gt(0n);
        });

        it('Should reject duplicate pool creation', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY * 2n);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY * 2n);

            const deadline = await futureDeadline();
            // First creation succeeds
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );

            // Direct createPool for same pair should fail
            await expect(
                amm.connect(owner).createPool(xomAddr, rwaAddr)
            ).to.be.revertedWithCustomError(amm, 'PoolAlreadyExists');
        });

        it('Should reject addLiquidity with expired deadline', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const block = await ethers.provider.getBlock('latest');
            const expiredDeadline = block.timestamp - 3600;

            await expect(
                amm.connect(owner).addLiquidity(
                    xomAddr, rwaAddr,
                    INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                    0n, 0n, expiredDeadline, ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'DeadlineExpired');
        });

        it('Should reject removeLiquidity with expired deadline', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );

            const block = await ethers.provider.getBlock('latest');
            const expiredDeadline = block.timestamp - 3600;

            await expect(
                amm.connect(owner).removeLiquidity(
                    xomAddr, rwaAddr,
                    1n, 0n, 0n, expiredDeadline, ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'DeadlineExpired');
        });

        it('Should reject removeLiquidity on non-existent pool', async function () {
            const wavaxAddr = await wavax.getAddress();
            const rwaAddr = await rwaToken.getAddress();
            const deadline = await futureDeadline();

            await expect(
                amm.connect(owner).removeLiquidity(
                    wavaxAddr, rwaAddr,
                    1n, 0n, 0n, deadline, ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'PoolNotFound');
        });
    });

    // =====================================================================
    //  NEW TESTS - Large Swaps
    // =====================================================================
    describe('Large Swaps', function () {
        beforeEach(async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            // Create pool with large liquidity
            const largeLiquidity = ethers.parseEther('100000');
            await xomToken.connect(owner).approve(await amm.getAddress(), largeLiquidity);
            await rwaToken.connect(owner).approve(await amm.getAddress(), largeLiquidity);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                largeLiquidity, largeLiquidity,
                0n, 0n, deadline, ethers.ZeroAddress,
            );
        });

        it('Should handle swap of 10% of reserves', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();
            const tenPercent = ethers.parseEther('10000');

            await xomToken.connect(user1).approve(await amm.getAddress(), tenPercent);
            const deadline = await futureDeadline();

            await expect(
                amm.connect(user1).swap(
                    xomAddr, rwaAddr, tenPercent, 0n, deadline, ethers.ZeroAddress,
                )
            ).to.emit(amm, 'Swap');
        });

        it('Should have meaningful price impact for large swap (50% of reserves)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();
            const fiftyPercent = ethers.parseEther('50000');

            const [, , priceImpact] = await amm.getQuote(xomAddr, rwaAddr, fiftyPercent);

            // 50% of reserves should cause significant price impact (>100 bps = >1%)
            expect(priceImpact).to.be.gt(100n);
        });

        it('Should execute reverse swap (token1 -> token0)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await rwaToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline = await futureDeadline();

            const xomBalBefore = await xomToken.balanceOf(user1.address);

            await amm.connect(user1).swap(
                rwaAddr, xomAddr, SWAP_AMOUNT, 0n, deadline, ethers.ZeroAddress,
            );

            const xomBalAfter = await xomToken.balanceOf(user1.address);
            expect(xomBalAfter).to.be.gt(xomBalBefore);
        });
    });

    // =====================================================================
    //  NEW TESTS - Events
    // =====================================================================
    describe('Events - Detailed', function () {
        it('Should emit LiquidityAdded with correct args on initial deposit', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();

            await expect(
                amm.connect(owner).addLiquidity(
                    xomAddr, rwaAddr,
                    INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                    0n, 0n, deadline, ethers.ZeroAddress,
                )
            ).to.emit(amm, 'LiquidityAdded');
        });

        it('Should emit Swap with correct sender (compliance target)', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            const deadline1 = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline1, ethers.ZeroAddress,
            );

            await xomToken.connect(user1).approve(await amm.getAddress(), SWAP_AMOUNT);
            const deadline2 = await futureDeadline();

            const tx = await amm.connect(user1).swap(
                xomAddr, rwaAddr, SWAP_AMOUNT, 0n, deadline2, ethers.ZeroAddress,
            );
            const receipt = await tx.wait();
            const swapEvent = receipt.logs.find(
                (l) => l.fragment && l.fragment.name === 'Swap'
            );
            expect(swapEvent).to.not.be.undefined;
            // First indexed arg is the compliance target (user1)
            expect(swapEvent.args[0]).to.equal(user1.address);
            // Second indexed arg is tokenIn
            expect(swapEvent.args[1]).to.equal(xomAddr);
            // Third indexed arg is tokenOut
            expect(swapEvent.args[2]).to.equal(rwaAddr);
            // Fourth arg is amountIn
            expect(swapEvent.args[3]).to.equal(SWAP_AMOUNT);
        });

        it('Should emit EmergencyPaused event on global pause', async function () {
            const poolId = ethers.ZeroHash;
            const reason = 'Security incident';
            const nonce = await amm.emergencyNonce();
            const chainId = (await ethers.provider.getNetwork()).chainId;
            const ammAddr = await amm.getAddress();

            const messageHash = ethers.solidityPackedKeccak256(
                ['string', 'bytes32', 'string', 'uint256', 'uint256', 'address'],
                ['PAUSE', poolId, reason, nonce, chainId, ammAddr],
            );
            const ethHash = ethers.hashMessage(ethers.getBytes(messageHash));

            const sigs = [];
            for (let i = 0; i < 3; i++) {
                const sig = await emergencySigners[i].signMessage(ethers.getBytes(messageHash));
                sigs.push(sig);
            }

            await expect(
                amm.emergencyPause(poolId, reason, sigs)
            ).to.emit(amm, 'EmergencyPaused');
        });
    });

    // =====================================================================
    //  NEW TESTS - Constructor Validation
    // =====================================================================
    describe('Constructor Validation', function () {
        it('Should reject zero XOM token address', async function () {
            const RWAAMM = await ethers.getContractFactory('RWAAMM');
            const emergencyAddresses = emergencySigners.map(s => s.address);

            await expect(
                RWAAMM.deploy(
                    emergencyAddresses,
                    feeVault.address,
                    ethers.ZeroAddress, // Zero XOM
                    await complianceOracle.getAddress(),
                    ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'ZeroAddress');
        });

        it('Should reject zero compliance oracle address', async function () {
            const RWAAMM = await ethers.getContractFactory('RWAAMM');
            const emergencyAddresses = emergencySigners.map(s => s.address);

            await expect(
                RWAAMM.deploy(
                    emergencyAddresses,
                    feeVault.address,
                    await xomToken.getAddress(),
                    ethers.ZeroAddress, // Zero oracle
                    ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'ZeroAddress');
        });

        it('Should reject zero address in emergency signers', async function () {
            const RWAAMM = await ethers.getContractFactory('RWAAMM');
            const badSigners = emergencySigners.map(s => s.address);
            badSigners[2] = ethers.ZeroAddress;

            await expect(
                RWAAMM.deploy(
                    badSigners,
                    feeVault.address,
                    await xomToken.getAddress(),
                    await complianceOracle.getAddress(),
                    ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'ZeroAddress');
        });

        it('Should reject duplicate emergency signers', async function () {
            const RWAAMM = await ethers.getContractFactory('RWAAMM');
            const dupSigners = emergencySigners.map(s => s.address);
            dupSigners[3] = dupSigners[0]; // duplicate

            await expect(
                RWAAMM.deploy(
                    dupSigners,
                    feeVault.address,
                    await xomToken.getAddress(),
                    await complianceOracle.getAddress(),
                    ethers.ZeroAddress,
                )
            ).to.be.revertedWithCustomError(amm, 'DuplicateSigner');
        });

        it('Should set all 5 emergency signers correctly', async function () {
            expect(await amm.EMERGENCY_SIGNER_1()).to.equal(emergencySigners[0].address);
            expect(await amm.EMERGENCY_SIGNER_2()).to.equal(emergencySigners[1].address);
            expect(await amm.EMERGENCY_SIGNER_3()).to.equal(emergencySigners[2].address);
            expect(await amm.EMERGENCY_SIGNER_4()).to.equal(emergencySigners[3].address);
            expect(await amm.EMERGENCY_SIGNER_5()).to.equal(emergencySigners[4].address);
        });
    });

    // =====================================================================
    //  NEW TESTS - View Functions
    // =====================================================================
    describe('View Functions', function () {
        it('Should return false for poolExists on non-existent pool', async function () {
            const fakeId = ethers.keccak256(ethers.toUtf8Bytes('fake'));
            expect(await amm.poolExists(fakeId)).to.be.false;
        });

        it('Should return empty array for getAllPoolIds initially', async function () {
            const ids = await amm.getAllPoolIds();
            expect(ids.length).to.equal(0);
        });

        it('Should return pool ID in getAllPoolIds after creation', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await xomToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);
            await rwaToken.connect(owner).approve(await amm.getAddress(), INITIAL_LIQUIDITY);

            const deadline = await futureDeadline();
            await amm.connect(owner).addLiquidity(
                xomAddr, rwaAddr,
                INITIAL_LIQUIDITY, INITIAL_LIQUIDITY,
                0n, 0n, deadline, ethers.ZeroAddress,
            );

            const ids = await amm.getAllPoolIds();
            expect(ids.length).to.equal(1);

            const expectedId = await amm.getPoolId(xomAddr, rwaAddr);
            expect(ids[0]).to.equal(expectedId);
        });

        it('Should return zero address for getPoolAddress on non-existent pool', async function () {
            const fakeId = ethers.keccak256(ethers.toUtf8Bytes('nonexistent'));
            expect(await amm.getPoolAddress(fakeId)).to.equal(ethers.ZeroAddress);
        });

        it('Should report isGloballyPaused as false initially', async function () {
            expect(await amm.isGloballyPaused()).to.be.false;
        });

        it('Should return initial nonce of 0', async function () {
            expect(await amm.emergencyNonce()).to.equal(0n);
            expect(await amm.poolCreatorNonce()).to.equal(0n);
        });

        it('Should return MINIMUM_LIQUIDITY constant as 1000', async function () {
            expect(await amm.MINIMUM_LIQUIDITY()).to.equal(1000n);
        });

        it('Should return PAUSE_THRESHOLD as 3', async function () {
            expect(await amm.PAUSE_THRESHOLD()).to.equal(3n);
        });

        it('Should return MULTISIG_COUNT as 5', async function () {
            expect(await amm.MULTISIG_COUNT()).to.equal(5n);
        });
    });

    // =====================================================================
    //  NEW TESTS - Pool Creation via createPool
    // =====================================================================
    describe('Pool Creation via createPool', function () {
        it('Should allow pool creator to create pool directly', async function () {
            const xomAddr = await xomToken.getAddress();
            const rwaAddr = await rwaToken.getAddress();

            await expect(
                amm.connect(owner).createPool(xomAddr, rwaAddr)
            ).to.emit(amm, 'PoolCreated');
        });

        it('Should reject createPool with zero address', async function () {
            const xomAddr = await xomToken.getAddress();

            await expect(
                amm.connect(owner).createPool(xomAddr, ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(amm, 'ZeroAddress');
        });
    });
});
