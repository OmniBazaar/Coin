const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * @title StableSwapPool Test Suite
 * @notice Exercises the Curve-style StableSwap pool: invariant correctness,
 *         add/remove liquidity (balanced + single-coin), exchange + getDy
 *         parity, fee routing to the vault, slippage near vs far from peg,
 *         Newton convergence edge cases, admin (deployer-direct) setters,
 *         A ramping, pause behavior, and revert paths.
 */
describe('StableSwapPool', function () {
    let owner;
    let user1;
    let user2;
    let feeVault;

    let pool;
    let coin0;
    let coin1;

    // Constants mirroring the contract
    const A = 100n; // amplification coefficient
    const FEE_BPS = 4n; // 0.04% trading fee
    const BPS = 10_000n;
    const FEE_LP_BPS = 7000n;
    const MINIMUM_LIQUIDITY = 1000n;

    // 18-decimal coins for the bulk of tests
    const E18 = 10n ** 18n;

    /**
     * @notice Future deadline helper (unused for this pool but kept for
     *         parity with sibling suites that need it).
     * @returns {Promise<number>} A future timestamp
     */
    async function latestTime() {
        const block = await ethers.provider.getBlock('latest');
        return block.timestamp;
    }

    /**
     * @notice Deploy a fresh pool seeded with `seed` of each 18-decimal coin.
     * @param {bigint} seed Initial balanced deposit per coin
     * @returns {Promise<void>}
     */
    async function seedPool(seed) {
        await coin0.connect(owner).approve(await pool.getAddress(), seed);
        await coin1.connect(owner).approve(await pool.getAddress(), seed);
        await pool.connect(owner).addLiquidity(seed, seed, 0);
    }

    beforeEach(async function () {
        const signers = await ethers.getSigners();
        owner = signers[0];
        user1 = signers[1];
        user2 = signers[2];
        feeVault = signers[3];

        const Mock = await ethers.getContractFactory('ERC20Mock');
        coin0 = await Mock.deploy('Stable Zero', 'STZ');
        await coin0.waitForDeployment();
        coin1 = await Mock.deploy('Stable One', 'STO');
        await coin1.waitForDeployment();

        const Pool = await ethers.getContractFactory('StableSwapPool');
        pool = await Pool.deploy(
            await coin0.getAddress(),
            await coin1.getAddress(),
            feeVault.address,
            A,
            FEE_BPS,
            owner.address,
            'StableSwap LP',
            'ssLP',
        );
        await pool.waitForDeployment();

        // Fund users (ERC20Mock mints 1e9 * 1e18 to deployer at construction)
        const fund = ethers.parseEther('1000000');
        for (const u of [user1, user2]) {
            await coin0.connect(owner).transfer(u.address, fund);
            await coin1.connect(owner).transfer(u.address, fund);
        }
    });

    describe('Deployment', function () {
        it('sets immutable addresses and initial parameters', async function () {
            expect(await pool.COIN0()).to.equal(await coin0.getAddress());
            expect(await pool.COIN1()).to.equal(await coin1.getAddress());
            expect(await pool.FEE_VAULT()).to.equal(feeVault.address);
            expect(await pool.tradingFeeBps()).to.equal(FEE_BPS);
            // 18-decimal coins => rate multiplier of 1
            expect(await pool.RATE0()).to.equal(1n);
            expect(await pool.RATE1()).to.equal(1n);
        });

        it('grants admin roles to the deployer-supplied admin', async function () {
            const adminRole = await pool.ADMIN_ROLE();
            const defaultAdmin = await pool.DEFAULT_ADMIN_ROLE();
            expect(await pool.hasRole(adminRole, owner.address)).to.equal(true);
            expect(
                await pool.hasRole(defaultAdmin, owner.address),
            ).to.equal(true);
        });

        it('returns the scaled A (A * A_PRECISION)', async function () {
            expect(await pool.getA()).to.equal(A * 100n);
        });

        it('reverts on identical coins', async function () {
            const Pool = await ethers.getContractFactory('StableSwapPool');
            await expect(
                Pool.deploy(
                    await coin0.getAddress(),
                    await coin0.getAddress(),
                    feeVault.address,
                    A,
                    FEE_BPS,
                    owner.address,
                    'x',
                    'x',
                ),
            ).to.be.revertedWithCustomError(Pool, 'IdenticalCoins');
        });

        it('reverts on zero address', async function () {
            const Pool = await ethers.getContractFactory('StableSwapPool');
            await expect(
                Pool.deploy(
                    ethers.ZeroAddress,
                    await coin1.getAddress(),
                    feeVault.address,
                    A,
                    FEE_BPS,
                    owner.address,
                    'x',
                    'x',
                ),
            ).to.be.revertedWithCustomError(Pool, 'ZeroAddress');
        });

        it('reverts on out-of-range A', async function () {
            const Pool = await ethers.getContractFactory('StableSwapPool');
            await expect(
                Pool.deploy(
                    await coin0.getAddress(),
                    await coin1.getAddress(),
                    feeVault.address,
                    0n,
                    FEE_BPS,
                    owner.address,
                    'x',
                    'x',
                ),
            ).to.be.revertedWithCustomError(Pool, 'InvalidA');
        });

        it('reverts on fee above the cap', async function () {
            const Pool = await ethers.getContractFactory('StableSwapPool');
            await expect(
                Pool.deploy(
                    await coin0.getAddress(),
                    await coin1.getAddress(),
                    feeVault.address,
                    A,
                    101n,
                    owner.address,
                    'x',
                    'x',
                ),
            ).to.be.revertedWithCustomError(Pool, 'FeeTooHigh');
        });
    });

    describe('Add liquidity & invariant', function () {
        it('first deposit mints D minus the locked minimum', async function () {
            const seed = ethers.parseEther('1000');
            await coin0.connect(owner).approve(await pool.getAddress(), seed);
            await coin1.connect(owner).approve(await pool.getAddress(), seed);
            await pool.connect(owner).addLiquidity(seed, seed, 0);

            // For a perfectly balanced pool D == sum of balances == 2*seed.
            const d = await pool.getInvariant();
            expect(d).to.equal(seed * 2n);

            const minted = await pool.balanceOf(owner.address);
            expect(minted).to.equal(d - MINIMUM_LIQUIDITY);
            // The minimum liquidity is locked at the dead address.
            const dead = '0x000000000000000000000000000000000000dEaD';
            expect(await pool.balanceOf(dead)).to.equal(MINIMUM_LIQUIDITY);
        });

        it('tracks reserves correctly after deposit', async function () {
            const seed = ethers.parseEther('500');
            await seedPool(seed);
            expect(await pool.reserve0()).to.equal(seed);
            expect(await pool.reserve1()).to.equal(seed);
        });

        it('subsequent balanced deposit mints proportionally', async function () {
            const seed = ethers.parseEther('1000');
            await seedPool(seed);
            const supplyBefore = await pool.totalSupply();

            const add = ethers.parseEther('1000');
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            await coin1.connect(user1).approve(await pool.getAddress(), add);
            await pool.connect(user1).addLiquidity(add, add, 0);

            // Doubling balanced reserves should roughly double the supply.
            const supplyAfter = await pool.totalSupply();
            // user1 minted ~= supplyBefore (since D doubled).
            const minted = await pool.balanceOf(user1.address);
            expect(minted).to.be.closeTo(
                supplyBefore + MINIMUM_LIQUIDITY,
                ethers.parseEther('0.001'),
            );
            expect(supplyAfter).to.be.gt(supplyBefore);
        });

        it('reverts when both amounts are zero', async function () {
            await expect(
                pool.connect(owner).addLiquidity(0, 0, 0),
            ).to.be.revertedWithCustomError(pool, 'ZeroAmount');
        });

        it('reverts when first deposit is below the minimum lock', async function () {
            // sqrt-free: D for tiny balanced deposit is 2*amount, must exceed
            // MINIMUM_LIQUIDITY (1000). Deposit 400 of each => D = 800 < 1000.
            await coin0.connect(owner).approve(await pool.getAddress(), 400n);
            await coin1.connect(owner).approve(await pool.getAddress(), 400n);
            await expect(
                pool.connect(owner).addLiquidity(400n, 400n, 0),
            ).to.be.revertedWithCustomError(pool, 'InitialDepositTooSmall');
        });

        it('reverts a one-sided first deposit (needs both coins)', async function () {
            const seed = ethers.parseEther('1000');
            await coin0.connect(owner).approve(await pool.getAddress(), seed);
            await expect(
                pool.connect(owner).addLiquidity(seed, 0, 0),
            ).to.be.revertedWithCustomError(
                pool,
                'FirstDepositNeedsBothCoins',
            );
        });

        it('allows a one-sided deposit after the pool is seeded', async function () {
            await seedPool(ethers.parseEther('100000'));
            const add = ethers.parseEther('1000');
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            const minted = await pool
                .connect(user1)
                .addLiquidity.staticCall(add, 0, 0);
            expect(minted).to.be.gt(0n);
            await expect(pool.connect(user1).addLiquidity(add, 0, 0)).to.not.be
                .reverted;
        });

        it('enforces the minMintAmount slippage guard', async function () {
            const seed = ethers.parseEther('1000');
            await seedPool(seed);
            const add = ethers.parseEther('10');
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            await coin1.connect(user1).approve(await pool.getAddress(), add);
            await expect(
                pool
                    .connect(user1)
                    .addLiquidity(add, add, ethers.parseEther('1000000')),
            ).to.be.revertedWithCustomError(pool, 'SlippageExceeded');
        });
    });

    describe('Exchange & getDy parity', function () {
        beforeEach(async function () {
            await seedPool(ethers.parseEther('100000'));
        });

        it('getDy exactly matches the executed exchange output', async function () {
            const dx = ethers.parseEther('1000');
            const quoted = await pool.getDy(0, 1, dx);

            await coin0.connect(user1).approve(await pool.getAddress(), dx);
            const before = await coin1.balanceOf(user1.address);
            await pool.connect(user1).exchange(0, 1, dx, 0);
            const after = await coin1.balanceOf(user1.address);

            expect(after - before).to.equal(quoted);
        });

        it('routes 30% of the fee to the vault, retains 70% as LP yield', async function () {
            const dx = ethers.parseEther('1000');
            const quoted = await pool.getDy(0, 1, dx);

            // Gross output before fee: dy = gross - totalFee.
            // totalFee = gross * FEE_BPS / BPS  => gross = dy / (1 - fee).
            // Recover totalFee precisely from contract math by reading event.
            await coin0.connect(user1).approve(await pool.getAddress(), dx);
            const vaultBefore = await coin1.balanceOf(feeVault.address);
            const tx = await pool.connect(user1).exchange(0, 1, dx, 0);
            const receipt = await tx.wait();

            // Parse TokenExchange event for the fee field.
            const iface = pool.interface;
            let totalFee;
            let tokensBought;
            for (const log of receipt.logs) {
                try {
                    const parsed = iface.parseLog(log);
                    if (parsed && parsed.name === 'TokenExchange') {
                        totalFee = parsed.args.fee;
                        tokensBought = parsed.args.tokensBought;
                    }
                } catch (e) {
                    // not our event; ignore
                }
            }
            expect(tokensBought).to.equal(quoted);

            const expectedVaultFee =
                totalFee - (totalFee * FEE_LP_BPS) / BPS;
            const vaultAfter = await coin1.balanceOf(feeVault.address);
            expect(vaultAfter - vaultBefore).to.equal(expectedVaultFee);
        });

        it('preserves/raises the invariant after a swap (LP fee accrual)', async function () {
            const dBefore = await pool.getInvariant();
            const dx = ethers.parseEther('500');
            await coin0.connect(user1).approve(await pool.getAddress(), dx);
            await pool.connect(user1).exchange(0, 1, dx, 0);
            const dAfter = await pool.getInvariant();
            // D must not decrease (the LP fee share is a donation to reserves).
            expect(dAfter).to.be.gte(dBefore);
        });

        it('low slippage near peg vs constant-product expectation', async function () {
            // A small trade near peg should return ~1:1 (minus fee), far
            // better than a constant-product pool of the same reserves.
            const dx = ethers.parseEther('100');
            const dy = await pool.getDy(0, 1, dx);
            // StableSwap near peg: output within ~0.1% of input (minus 0.04%).
            expect(dy).to.be.gt(ethers.parseEther('99.8'));
            expect(dy).to.be.lt(dx); // never more than input
        });

        it('higher slippage far from peg', async function () {
            // A trade large relative to reserves should incur visible slippage.
            const reserve = ethers.parseEther('100000');
            const dxSmall = ethers.parseEther('100');
            const dxLarge = ethers.parseEther('60000');

            const dySmall = await pool.getDy(0, 1, dxSmall);
            const dyLarge = await pool.getDy(0, 1, dxLarge);

            const rateSmall = (dySmall * E18) / dxSmall;
            const rateLarge = (dyLarge * E18) / dxLarge;
            // Effective price per unit must be worse for the large trade.
            expect(rateLarge).to.be.lt(rateSmall);
            // And the large trade cannot drain more than the output reserve.
            expect(dyLarge).to.be.lt(reserve);
        });

        it('enforces minDy slippage protection', async function () {
            const dx = ethers.parseEther('1000');
            await coin0.connect(user1).approve(await pool.getAddress(), dx);
            await expect(
                pool
                    .connect(user1)
                    .exchange(0, 1, dx, ethers.parseEther('1000000')),
            ).to.be.revertedWithCustomError(pool, 'SlippageExceeded');
        });

        it('reverts on invalid coin index', async function () {
            await expect(
                pool.getDy(0, 2, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(pool, 'InvalidCoinIndex');
            await expect(
                pool.getDy(1, 1, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(pool, 'InvalidCoinIndex');
        });

        it('reverts on zero dx', async function () {
            await coin0.connect(user1).approve(await pool.getAddress(), 1n);
            await expect(
                pool.connect(user1).exchange(0, 1, 0, 0),
            ).to.be.revertedWithCustomError(pool, 'ZeroAmount');
        });

        it('swaps symmetrically in the reverse direction', async function () {
            const dx = ethers.parseEther('1000');
            const dy = await pool.getDy(1, 0, dx);
            await coin1.connect(user1).approve(await pool.getAddress(), dx);
            const before = await coin0.balanceOf(user1.address);
            await pool.connect(user1).exchange(1, 0, dx, 0);
            const after = await coin0.balanceOf(user1.address);
            expect(after - before).to.equal(dy);
        });
    });

    describe('Remove liquidity (balanced)', function () {
        beforeEach(async function () {
            await seedPool(ethers.parseEther('10000'));
        });

        it('returns pro-rata reserves and burns LP', async function () {
            const lp = await pool.balanceOf(owner.address);
            const supply = await pool.totalSupply();
            const r0 = await pool.reserve0();
            const r1 = await pool.reserve1();

            const expected0 = (r0 * lp) / supply;
            const expected1 = (r1 * lp) / supply;

            const b0 = await coin0.balanceOf(owner.address);
            const b1 = await coin1.balanceOf(owner.address);

            await pool.connect(owner).removeLiquidity(lp, 0, 0);

            expect((await coin0.balanceOf(owner.address)) - b0).to.equal(
                expected0,
            );
            expect((await coin1.balanceOf(owner.address)) - b1).to.equal(
                expected1,
            );
            expect(await pool.balanceOf(owner.address)).to.equal(0n);
        });

        it('works even while the pool is paused (exit always allowed)', async function () {
            await pool.connect(owner).setPaused(true);
            const lp = await pool.balanceOf(owner.address);
            await expect(
                pool.connect(owner).removeLiquidity(lp, 0, 0),
            ).to.not.be.reverted;
        });

        it('reverts when burning more than balance', async function () {
            const lp = await pool.balanceOf(owner.address);
            await expect(
                pool.connect(owner).removeLiquidity(lp + 1n, 0, 0),
            ).to.be.revertedWithCustomError(pool, 'InsufficientLPBalance');
        });

        it('enforces min-out slippage', async function () {
            const lp = await pool.balanceOf(owner.address);
            await expect(
                pool
                    .connect(owner)
                    .removeLiquidity(lp, ethers.parseEther('1000000'), 0),
            ).to.be.revertedWithCustomError(pool, 'SlippageExceeded');
        });

        it('reverts on zero LP amount', async function () {
            await expect(
                pool.connect(owner).removeLiquidity(0, 0, 0),
            ).to.be.revertedWithCustomError(pool, 'ZeroAmount');
        });
    });

    describe('Remove liquidity (single coin)', function () {
        beforeEach(async function () {
            await seedPool(ethers.parseEther('100000'));
            // Give user1 an LP position via a balanced add.
            const add = ethers.parseEther('10000');
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            await coin1.connect(user1).approve(await pool.getAddress(), add);
            await pool.connect(user1).addLiquidity(add, add, 0);
        });

        it('calcWithdrawOneCoin matches the executed withdrawal', async function () {
            const lp = await pool.balanceOf(user1.address);
            const half = lp / 2n;
            const preview = await pool.calcWithdrawOneCoin(half, 0);

            const before = await coin0.balanceOf(user1.address);
            await pool.connect(user1).removeLiquidityOneCoin(half, 0, 0);
            const after = await coin0.balanceOf(user1.address);
            expect(after - before).to.equal(preview);
        });

        it('sends the vault its fee share on single-coin exit', async function () {
            const lp = await pool.balanceOf(user1.address);
            const vaultBefore = await coin1.balanceOf(feeVault.address);
            await pool.connect(user1).removeLiquidityOneCoin(lp, 1, 0);
            const vaultAfter = await coin1.balanceOf(feeVault.address);
            // Non-zero fee routed to the vault (imbalance fee applied).
            expect(vaultAfter).to.be.gt(vaultBefore);
        });

        it('reverts on bad coin index', async function () {
            const lp = await pool.balanceOf(user1.address);
            await expect(
                pool.connect(user1).removeLiquidityOneCoin(lp, 2, 0),
            ).to.be.revertedWithCustomError(pool, 'InvalidCoinIndex');
        });

        it('enforces min-out slippage', async function () {
            const lp = await pool.balanceOf(user1.address);
            await expect(
                pool
                    .connect(user1)
                    .removeLiquidityOneCoin(lp, 0, ethers.parseEther('1000000')),
            ).to.be.revertedWithCustomError(pool, 'SlippageExceeded');
        });
    });

    describe('Imbalance fee model (M-1 / M-2 Curve alignment)', function () {
        beforeEach(async function () {
            await seedPool(ethers.parseEther('1000000'));
        });

        it('balanced add (pool ratio) charges no imbalance fee', async function () {
            const add = ethers.parseEther('10000');
            const v0Before = await coin0.balanceOf(feeVault.address);
            const v1Before = await coin1.balanceOf(feeVault.address);

            await coin0.connect(user1).approve(await pool.getAddress(), add);
            await coin1.connect(user1).approve(await pool.getAddress(), add);
            await pool.connect(user1).addLiquidity(add, add, 0);

            // A perfectly balanced deposit deviates 0 from the ideal => no fee.
            expect(await coin0.balanceOf(feeVault.address)).to.equal(v0Before);
            expect(await coin1.balanceOf(feeVault.address)).to.equal(v1Before);
        });

        it('one-sided add charges a fee and mints less than the no-fee case', async function () {
            const add = ethers.parseEther('10000');

            // No-fee baseline: temporarily zero the trading fee, measure mint.
            await pool.connect(owner).setTradingFee(0n);
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            const mintNoFee = await pool
                .connect(user1)
                .addLiquidity.staticCall(add, 0, 0);

            // Restore the fee and execute a real one-sided add.
            await pool.connect(owner).setTradingFee(FEE_BPS);
            const v0Before = await coin0.balanceOf(feeVault.address);
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            const mintWithFee = await pool
                .connect(user1)
                .addLiquidity.staticCall(add, 0, 0);
            await pool.connect(user1).addLiquidity(add, 0, 0);

            // Fee routed to the vault in coin0 (the imbalanced coin).
            expect(
                (await coin0.balanceOf(feeVault.address)) - v0Before,
            ).to.be.gt(0n);
            // Fewer LP minted than the fee-free add of the same deposit.
            expect(mintWithFee).to.be.lt(mintNoFee);
        });

        it('single-coin withdraw charges only the imbalance fee (30% to vault)', async function () {
            // Give user1 a balanced LP position.
            const add = ethers.parseEther('100000');
            await coin0.connect(user1).approve(await pool.getAddress(), add);
            await coin1.connect(user1).approve(await pool.getAddress(), add);
            await pool.connect(user1).addLiquidity(add, add, 0);

            const lp = await pool.balanceOf(user1.address);
            // Withdraw a small slice to coin0 so the deviation (and fee) stay
            // small relative to the output — the key M-1 property.
            const burn = lp / 100n;

            const vaultBefore = await coin0.balanceOf(feeVault.address);
            const before = await coin0.balanceOf(user1.address);
            await pool.connect(user1).removeLiquidityOneCoin(burn, 0, 0);
            const net = (await coin0.balanceOf(user1.address)) - before;
            const vaultFee =
                (await coin0.balanceOf(feeVault.address)) - vaultBefore;

            // The fee charged on a near-balanced single-coin withdraw must be
            // a small fraction of the output — proving it is the imbalance fee,
            // not a fee on the full grossDy (which at FEE_BPS=4 would have been
            // net*4/9996 of net). Here it is far smaller.
            expect(vaultFee).to.be.gt(0n);
            const fullFeeApprox = (net * FEE_BPS) / (BPS - FEE_BPS);
            const vaultOfFull =
                fullFeeApprox - (fullFeeApprox * FEE_LP_BPS) / BPS;
            // Imbalance-only fee is much smaller than the old full-output fee.
            expect(vaultFee).to.be.lt(vaultOfFull);
        });

        it('add+single-coin-withdraw cannot undercut a direct exchange', async function () {
            const dx = ethers.parseEther('10000');

            // Path A: direct exchange of dx coin0 -> coin1.
            const directDy = await pool.getDy(0, 1, dx);

            // Path B: one-sided add of dx coin0, then withdraw all that LP to
            // coin1. Use staticCall chained on a fresh fork-like sequence.
            await coin0.connect(user2).approve(await pool.getAddress(), dx);
            const minted = await pool
                .connect(user2)
                .addLiquidity.staticCall(dx, 0, 0);
            await pool.connect(user2).addLiquidity(dx, 0, 0);
            const roundTripDy = await pool.calcWithdrawOneCoin(minted, 1);

            // The round-trip must not yield MORE coin1 than the direct swap
            // (allowing a tiny rounding tolerance). If it did, an attacker
            // could extract value by add+withdraw instead of swapping.
            const tolerance = ethers.parseEther('1');
            expect(roundTripDy).to.be.lte(directDy + tolerance);
        });
    });

    describe('Fail-closed guards (M-3 / L-1)', function () {
        it('reverts a fee-on-transfer input token on add', async function () {
            const Fot = await ethers.getContractFactory(
                'MockFeeOnTransferToken',
            );
            const fot = await Fot.deploy('Fee', 'FEE', 100n); // 1% burn
            await fot.waitForDeployment();

            const Pool = await ethers.getContractFactory('StableSwapPool');
            const fotPool = await Pool.deploy(
                await fot.getAddress(),
                await coin1.getAddress(),
                feeVault.address,
                A,
                FEE_BPS,
                owner.address,
                'fot',
                'fot',
            );
            await fotPool.waitForDeployment();

            const seed = ethers.parseEther('1000');
            await fot.mint(owner.address, seed);
            await fot
                .connect(owner)
                .approve(await fotPool.getAddress(), seed);
            await coin1
                .connect(owner)
                .approve(await fotPool.getAddress(), seed);

            await expect(
                fotPool.connect(owner).addLiquidity(seed, seed, 0),
            ).to.be.revertedWithCustomError(
                fotPool,
                'FeeOnTransferNotSupported',
            );
        });

        it('reverts a fee-on-transfer input token on exchange', async function () {
            // Toggle-fee mock: seed the pool with the fee OFF (exact transfers
            // pass the guard), then turn the fee ON and verify the exchange
            // input pull reverts FeeOnTransferNotSupported.
            const Fot = await ethers.getContractFactory(
                'FeeOnTransferToggleToken',
            );
            const fot = await Fot.deploy('Fee', 'FEE', 0n); // fee off initially
            await fot.waitForDeployment();

            const Pool = await ethers.getContractFactory('StableSwapPool');
            const fotPool = await Pool.deploy(
                await fot.getAddress(),
                await coin1.getAddress(),
                feeVault.address,
                A,
                FEE_BPS,
                owner.address,
                'fot2',
                'fot2',
            );
            await fotPool.waitForDeployment();

            const seed = ethers.parseEther('100000');
            await fot.mint(owner.address, seed);
            await fot
                .connect(owner)
                .approve(await fotPool.getAddress(), seed);
            await coin1
                .connect(owner)
                .approve(await fotPool.getAddress(), seed);
            // Seed succeeds with the fee off.
            await fotPool.connect(owner).addLiquidity(seed, seed, 0);

            // Now enable the transfer fee and attempt a swap using the FoT
            // token as the input coin (index 0).
            await fot.setFeeBps(100n); // 1% burn
            const dx = ethers.parseEther('1000');
            await fot.mint(user1.address, dx);
            await fot.connect(user1).approve(await fotPool.getAddress(), dx);
            await expect(
                fotPool.connect(user1).exchange(0, 1, dx, 0),
            ).to.be.revertedWithCustomError(
                fotPool,
                'FeeOnTransferNotSupported',
            );
        });

        it('dust swap reverts cleanly (no arithmetic panic)', async function () {
            await seedPool(ethers.parseEther('100000'));
            // A 1-wei swap rounds the output to zero after the -1 rounding.
            await coin0.connect(user1).approve(await pool.getAddress(), 1n);
            await expect(
                pool.connect(user1).exchange(0, 1, 1n, 0),
            ).to.be.revertedWithCustomError(pool, 'InsufficientOutput');
        });

        it('dust single-coin withdraw reverts cleanly', async function () {
            await seedPool(ethers.parseEther('100000'));
            // Burning 1 wei of LP yields a zero-rounded output.
            await expect(
                pool.connect(owner).removeLiquidityOneCoin(1n, 0, 0),
            ).to.be.revertedWithCustomError(pool, 'InsufficientOutput');
        });
    });

    describe('Mixed decimals (6 vs 18)', function () {
        let usdc;
        let xom;
        let mixedPool;

        beforeEach(async function () {
            const Dec = await ethers.getContractFactory('ERC20MockDecimals');
            usdc = await Dec.deploy('USD Coin', 'USDC', 6);
            await usdc.waitForDeployment();
            xom = await Dec.deploy('Omni', 'XOM', 18);
            await xom.waitForDeployment();

            const Pool = await ethers.getContractFactory('StableSwapPool');
            mixedPool = await Pool.deploy(
                await usdc.getAddress(),
                await xom.getAddress(),
                feeVault.address,
                A,
                FEE_BPS,
                owner.address,
                'mix',
                'mix',
            );
            await mixedPool.waitForDeployment();

            await usdc.mint(owner.address, 1_000_000n * 10n ** 6n);
            await xom.mint(owner.address, ethers.parseEther('1000000'));
            await usdc.mint(user1.address, 1_000_000n * 10n ** 6n);
            await xom.mint(user1.address, ethers.parseEther('1000000'));
        });

        it('normalizes decimals via rate multipliers', async function () {
            expect(await mixedPool.RATE0()).to.equal(10n ** 12n); // 6 -> 18
            expect(await mixedPool.RATE1()).to.equal(1n); // 18 -> 18
        });

        it('treats 1 USDC ~= 1 XOM near peg', async function () {
            const usdcSeed = 100_000n * 10n ** 6n;
            const xomSeed = ethers.parseEther('100000');
            await usdc
                .connect(owner)
                .approve(await mixedPool.getAddress(), usdcSeed);
            await xom
                .connect(owner)
                .approve(await mixedPool.getAddress(), xomSeed);
            await mixedPool
                .connect(owner)
                .addLiquidity(usdcSeed, xomSeed, 0);

            // Swap 1000 USDC (6 dp) -> expect ~1000 XOM (18 dp) minus fee.
            const dxUsdc = 1000n * 10n ** 6n;
            const dyXom = await mixedPool.getDy(0, 1, dxUsdc);
            expect(dyXom).to.be.gt(ethers.parseEther('999'));
            expect(dyXom).to.be.lt(ethers.parseEther('1000'));
        });

        it('rejects tokens with more than 18 decimals', async function () {
            const Dec = await ethers.getContractFactory('ERC20MockDecimals');
            const weird = await Dec.deploy('Weird', 'WRD', 24);
            await weird.waitForDeployment();
            const Pool = await ethers.getContractFactory('StableSwapPool');
            await expect(
                Pool.deploy(
                    await weird.getAddress(),
                    await xom.getAddress(),
                    feeVault.address,
                    A,
                    FEE_BPS,
                    owner.address,
                    'x',
                    'x',
                ),
            ).to.be.revertedWithCustomError(Pool, 'UnsupportedDecimals');
        });
    });

    describe('Newton convergence edge cases', function () {
        it('converges for a highly imbalanced pool', async function () {
            // Seed a balanced pool, then push it far out of balance and
            // confirm getDy still returns a sane value (no DidNotConverge).
            await seedPool(ethers.parseEther('100000'));
            const huge = ethers.parseEther('90000');
            await coin0.connect(user1).approve(await pool.getAddress(), huge);
            await pool.connect(user1).exchange(0, 1, huge, 0);

            // Now coin1 reserve is depleted; quoting another large coin0->coin1
            // must still converge and be bounded by remaining reserve.
            const r1 = await pool.reserve1();
            const dy = await pool.getDy(0, 1, ethers.parseEther('10000'));
            expect(dy).to.be.lt(r1);
            expect(dy).to.be.gt(0n);
        });

        it('converges with a very high amplification coefficient', async function () {
            const Pool = await ethers.getContractFactory('StableSwapPool');
            const hiA = await Pool.deploy(
                await coin0.getAddress(),
                await coin1.getAddress(),
                feeVault.address,
                100000n,
                FEE_BPS,
                owner.address,
                'hiA',
                'hiA',
            );
            await hiA.waitForDeployment();
            const seed = ethers.parseEther('100000');
            await coin0.connect(owner).approve(await hiA.getAddress(), seed);
            await coin1.connect(owner).approve(await hiA.getAddress(), seed);
            await hiA.connect(owner).addLiquidity(seed, seed, 0);

            const dy = await hiA.getDy(0, 1, ethers.parseEther('1000'));
            // Very high A => almost 1:1 minus fee.
            expect(dy).to.be.gt(ethers.parseEther('999.5'));
        });
    });

    describe('Admin: deployer-direct setters', function () {
        it('admin can change the trading fee immediately (no delay)', async function () {
            await expect(pool.connect(owner).setTradingFee(10n))
                .to.emit(pool, 'TradingFeeUpdated')
                .withArgs(FEE_BPS, 10n);
            expect(await pool.tradingFeeBps()).to.equal(10n);
        });

        it('rejects a fee above the cap', async function () {
            await expect(
                pool.connect(owner).setTradingFee(101n),
            ).to.be.revertedWithCustomError(pool, 'FeeTooHigh');
        });

        it('non-admin cannot change the fee', async function () {
            await expect(
                pool.connect(user1).setTradingFee(10n),
            ).to.be.revertedWithCustomError(
                pool,
                'AccessControlUnauthorizedAccount',
            );
        });

        it('admin can pause and unpause', async function () {
            await seedPool(ethers.parseEther('10000'));
            await pool.connect(owner).setPaused(true);
            const dx = ethers.parseEther('100');
            await coin0.connect(user1).approve(await pool.getAddress(), dx);
            await expect(
                pool.connect(user1).exchange(0, 1, dx, 0),
            ).to.be.revertedWithCustomError(pool, 'PoolPaused');

            await pool.connect(owner).setPaused(false);
            await expect(pool.connect(user1).exchange(0, 1, dx, 0)).to.not.be
                .reverted;
        });
    });

    describe('A ramping', function () {
        it('schedules a ramp and interpolates A over time', async function () {
            const now = await latestTime();
            const future = now + 2 * 24 * 60 * 60; // 2 days
            await expect(pool.connect(owner).rampA(200n, future)).to.emit(
                pool,
                'RampA',
            );

            // Immediately after scheduling, A is ~unchanged (still ~100*100).
            const aStart = await pool.getA();
            expect(aStart).to.be.closeTo(100n * 100n, 100n);

            // Advance ~1 day (halfway) and expect A near 150*100.
            await ethers.provider.send('evm_increaseTime', [24 * 60 * 60]);
            await ethers.provider.send('evm_mine', []);
            const aMid = await pool.getA();
            expect(aMid).to.be.closeTo(150n * 100n, 50n * 100n);

            // Advance past the end; A reaches the target exactly.
            await ethers.provider.send('evm_increaseTime', [2 * 24 * 60 * 60]);
            await ethers.provider.send('evm_mine', []);
            expect(await pool.getA()).to.equal(200n * 100n);
        });

        it('rejects a ramp that completes too fast', async function () {
            const now = await latestTime();
            await expect(
                pool.connect(owner).rampA(200n, now + 60),
            ).to.be.revertedWithCustomError(pool, 'ARampTooFast');
        });

        it('rejects a ramp larger than 10x', async function () {
            const now = await latestTime();
            const future = now + 2 * 24 * 60 * 60;
            await expect(
                pool.connect(owner).rampA(2000n, future),
            ).to.be.revertedWithCustomError(pool, 'ARampTooLarge');
        });

        it('stopRampA freezes A at the current value', async function () {
            const now = await latestTime();
            const future = now + 4 * 24 * 60 * 60;
            await pool.connect(owner).rampA(200n, future);
            await ethers.provider.send('evm_increaseTime', [24 * 60 * 60]);
            await ethers.provider.send('evm_mine', []);
            const aBeforeStop = await pool.getA();
            await pool.connect(owner).stopRampA();
            // After stop, A no longer moves even as time passes.
            await ethers.provider.send('evm_increaseTime', [10 * 24 * 60 * 60]);
            await ethers.provider.send('evm_mine', []);
            expect(await pool.getA()).to.equal(aBeforeStop);
        });

        it('non-admin cannot ramp', async function () {
            const now = await latestTime();
            await expect(
                pool.connect(user1).rampA(200n, now + 2 * 24 * 60 * 60),
            ).to.be.revertedWithCustomError(
                pool,
                'AccessControlUnauthorizedAccount',
            );
        });
    });
});
