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
    let feeCollectorOwner;
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
    let feeCollector;
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
        feeCollectorOwner = signers[3];

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

        // Pre-compute AMM address so the fee collector's immutable AMM_CONTRACT
        // is correct from deployment (both AMM and FeeCollector use immutables).
        const deployerNonce = await ethers.provider.getTransactionCount(owner.address);
        // FeeCollector will be deployed at nonce, AMM at nonce+1
        const predictedAmmAddress = ethers.getCreateAddress({
            from: owner.address,
            nonce: deployerNonce + 1,
        });

        // Deploy fee collector with predicted AMM address
        const FeeCollector = await ethers.getContractFactory('RWAFeeCollector');
        feeCollector = await FeeCollector.deploy(
            await xomToken.getAddress(),
            owner.address, // staking pool
            predictedAmmAddress, // AMM contract (pre-computed)
            owner.address, // liquidity pool
            owner.address, // admin
        );
        await feeCollector.waitForDeployment();

        // Deploy RWAAMM (will land at predictedAmmAddress)
        const emergencyAddresses = emergencySigners.map(s => s.address);
        const RWAAMM = await ethers.getContractFactory('RWAAMM');
        amm = await RWAAMM.deploy(
            emergencyAddresses,
            await feeCollector.getAddress(),
            await xomToken.getAddress(),
            await complianceOracle.getAddress(),
        );
        await amm.waitForDeployment();

        // Deploy router
        const Router = await ethers.getContractFactory('RWARouter');
        router = await Router.deploy(await amm.getAddress());
        await router.waitForDeployment();

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
            expect(await amm.FEE_COLLECTOR()).to.equal(await feeCollector.getAddress());
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
                    ethers.ZeroAddress, // Invalid fee collector
                    await xomToken.getAddress(),
                    await complianceOracle.getAddress(),
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

    describe('RWAFeeCollector', function () {
        it('Should deploy with correct parameters', async function () {
            expect(await feeCollector.XOM_TOKEN()).to.equal(await xomToken.getAddress());
            expect(await feeCollector.STAKING_POOL()).to.equal(owner.address);
        });

        it('Should have correct fee distribution ratios', async function () {
            // FEE_LP_BPS (70%) is on the AMM contract, not the FeeCollector.
            // The FeeCollector only receives 30% of the protocol fee and
            // splits it into staking (2/3 = 20%) and liquidity (1/3 = 10%).
            expect(await amm.FEE_LP_BPS()).to.equal(7000n); // 70% (on AMM)
            expect(await feeCollector.FEE_STAKING_BPS()).to.equal(2000n); // 20%
            expect(await feeCollector.FEE_LIQUIDITY_BPS()).to.equal(1000n); // 10%
        });

        it('Should track fee distribution state', async function () {
            // Total distributed fees should be zero initially
            expect(await feeCollector.totalFeesDistributed()).to.equal(0n);
            expect(await feeCollector.totalFeesToLiquidity()).to.equal(0n);
            // Initial epoch should be 0
            expect(await feeCollector.currentEpoch()).to.equal(0n);
        });
    });

    describe('RWAComplianceOracle', function () {
        it('Should deploy with correct registrar', async function () {
            expect(await complianceOracle.registrar()).to.equal(owner.address);
        });

        it('Should register token', async function () {
            const xomAddr = await xomToken.getAddress();

            await expect(
                complianceOracle.connect(owner).registerToken(xomAddr, ethers.ZeroAddress)
            ).to.emit(complianceOracle, 'TokenRegistered');

            expect(await complianceOracle.isTokenRegistered(xomAddr)).to.be.true;
        });

        it('Should check compliance for registered token', async function () {
            const xomAddr = await xomToken.getAddress();

            await complianceOracle.connect(owner).registerToken(xomAddr, ethers.ZeroAddress);

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
});
