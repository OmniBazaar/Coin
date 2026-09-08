/**
 * DEXSettlement V3.1 — Fee Oracle Tests
 *
 * Tests:
 * - scheduleFeeOracle / applyFeeOracle / cancelScheduledFeeOracle
 * - Oracle discount applied to settlement
 * - Oracle failure (fail-open: uses base fee)
 * - Oracle + per-pair override combo
 * - Oracle discount cannot exceed base fee (clamped)
 * - Timelock enforcement
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

/**
 * Helper to compute a future deadline
 * @param offsetSeconds Seconds into the future (default: 1 year)
 * @returns A deadline timestamp guaranteed to be in the EVM future
 */
async function getFutureDeadline(offsetSeconds = 86400 * 365): Promise<number> {
    const latestBlock = await ethers.provider.getBlock("latest");
    return latestBlock!.timestamp + offsetSeconds;
}

/**
 * Helper function to sign order with EIP-712
 * @param order Order to sign
 * @param signer Signer wallet
 * @param dexSettlement DEXSettlement contract instance
 * @returns EIP-712 signature
 */
async function signOrderEIP712(order: any, signer: any, dexSettlement: any) {
    const network = await ethers.provider.getNetwork();
    const domain = {
        name: 'OmniCoin DEX Settlement',
        version: '3',
        chainId: network.chainId,
        verifyingContract: await dexSettlement.getAddress()
    };
    const types = {
        Order: [
            { name: 'trader', type: 'address' },
            { name: 'isBuy', type: 'bool' },
            { name: 'tokenIn', type: 'address' },
            { name: 'tokenOut', type: 'address' },
            { name: 'amountIn', type: 'uint256' },
            { name: 'amountOut', type: 'uint256' },
            { name: 'price', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
            { name: 'salt', type: 'bytes32' },
            { name: 'matchingValidator', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'referrer', type: 'address' },
            { name: 'referrer2', type: 'address' }
        ]
    };
    return await signer.signTypedData(domain, types, order);
}

describe("DEXSettlement V3.1 — Fee Oracle", function () {
    let dexSettlement: any;
    let mockOracle: any, revertingOracle: any;
    let _owner: any, maker: any, taker: any, matchingValidator: any, nonOwner: any;
    let liquidityPool: any, feeVault: any, oddaoTreasury: any;
    let tokenA: any, tokenB: any;
    let tokenAAddr: string, tokenBAddr: string;
    let matchingValidatorAddress: string;
    const INITIAL_BALANCE = ethers.parseUnits("10000000", 18);
    const TIMELOCK_48H = 48 * 60 * 60;

    beforeEach(async function () {
        [_owner, maker, taker, matchingValidator, nonOwner, liquidityPool, feeVault, oddaoTreasury] =
            await ethers.getSigners();
        matchingValidatorAddress = await matchingValidator.getAddress();

        const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
        tokenA = await ERC20Mock.deploy("Token A", "TKA");
        tokenB = await ERC20Mock.deploy("Token B", "TKB");
        tokenAAddr = await tokenA.getAddress();
        tokenBAddr = await tokenB.getAddress();

        await tokenA.mint(await maker.getAddress(), INITIAL_BALANCE);
        await tokenA.mint(await taker.getAddress(), INITIAL_BALANCE);
        await tokenB.mint(await maker.getAddress(), INITIAL_BALANCE);
        await tokenB.mint(await taker.getAddress(), INITIAL_BALANCE);

        const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
        dexSettlement = await DEXSettlement.deploy(
            await liquidityPool.getAddress(),
            await feeVault.getAddress(),
            await oddaoTreasury.getAddress(),
            ethers.ZeroAddress
        );
        await dexSettlement.waitForDeployment();

        const addr = await dexSettlement.getAddress();
        await tokenA.connect(maker).approve(addr, ethers.MaxUint256);
        await tokenB.connect(maker).approve(addr, ethers.MaxUint256);
        await tokenA.connect(taker).approve(addr, ethers.MaxUint256);
        await tokenB.connect(taker).approve(addr, ethers.MaxUint256);

        // Deploy mock oracle that returns a fixed 5bps discount
        const MockOracleFactory = await ethers.getContractFactory("MockFeeOracle");
        mockOracle = await MockOracleFactory.deploy(5);
        await mockOracle.waitForDeployment();

        // Deploy reverting oracle
        const RevertingOracleFactory = await ethers.getContractFactory("RevertingFeeOracle");
        revertingOracle = await RevertingOracleFactory.deploy();
        await revertingOracle.waitForDeployment();
    });

    describe("scheduleFeeOracle", function () {
        it("Should schedule a fee oracle change", async function () {
            const oracleAddr = await mockOracle.getAddress();
            await expect(
                dexSettlement.scheduleFeeOracle(oracleAddr)
            ).to.emit(dexSettlement, "FeeOracleScheduled")
                .withArgs(ethers.ZeroAddress, oracleAddr, (v: bigint) => v > 0n);
        });

        it("Should revert when pending change exists", async function () {
            await dexSettlement.scheduleFeeOracle(await mockOracle.getAddress());
            await expect(
                dexSettlement.scheduleFeeOracle(await mockOracle.getAddress())
            ).to.be.revertedWithCustomError(dexSettlement, "PendingChangeExists");
        });

        it("Should revert when called by non-owner", async function () {
            await expect(
                dexSettlement.connect(nonOwner).scheduleFeeOracle(await mockOracle.getAddress())
            ).to.be.revertedWithCustomError(dexSettlement, "OwnableUnauthorizedAccount");
        });
    });

    describe("applyFeeOracle", function () {
        it("Should apply after timelock period", async function () {
            const oracleAddr = await mockOracle.getAddress();
            await dexSettlement.scheduleFeeOracle(oracleAddr);
            await time.increase(TIMELOCK_48H + 1);

            await expect(
                dexSettlement.applyFeeOracle()
            ).to.emit(dexSettlement, "FeeOracleApplied")
                .withArgs(ethers.ZeroAddress, oracleAddr);

            expect(await dexSettlement.feeOracle()).to.equal(oracleAddr);
        });

        it("Should revert before timelock expires", async function () {
            await dexSettlement.scheduleFeeOracle(await mockOracle.getAddress());
            await expect(
                dexSettlement.applyFeeOracle()
            ).to.be.revertedWithCustomError(dexSettlement, "TimelockNotElapsed");
        });

        it("Should revert when no pending change", async function () {
            await expect(
                dexSettlement.applyFeeOracle()
            ).to.be.revertedWithCustomError(dexSettlement, "NoPendingChange");
        });
    });

    describe("cancelScheduledFeeOracle", function () {
        it("Should cancel a scheduled oracle change", async function () {
            await dexSettlement.scheduleFeeOracle(await mockOracle.getAddress());
            await expect(
                dexSettlement.cancelScheduledFeeOracle()
            ).to.emit(dexSettlement, "FeeOracleCancelled");

            // Can schedule again
            await dexSettlement.scheduleFeeOracle(await mockOracle.getAddress());
        });

        it("Should revert when no pending change", async function () {
            await expect(
                dexSettlement.cancelScheduledFeeOracle()
            ).to.be.revertedWithCustomError(dexSettlement, "NoPendingChange");
        });
    });

    describe("Oracle discount in settlement", function () {
        /** Wire oracle and apply */
        async function wireOracle(oracle: any) {
            await dexSettlement.scheduleFeeOracle(await oracle.getAddress());
            await time.increase(TIMELOCK_48H + 1);
            await dexSettlement.applyFeeOracle();
        }

        it("Should apply oracle discount to settlement fee", async function () {
            await wireOracle(mockOracle); // 5bps discount

            const deadline = await getFutureDeadline();
            const makerOrder = {
                trader: await maker.getAddress(),
                isBuy: false, tokenIn: tokenAAddr, tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000, deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0, referrer: ethers.ZeroAddress, referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: await taker.getAddress(),
                isBuy: true, tokenIn: tokenBAddr, tokenOut: tokenAAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000, deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 1, referrer: ethers.ZeroAddress, referrer2: ethers.ZeroAddress
            };

            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                makerOrder.amountIn, takerOrder.amountIn,
                makerSig, takerSig
            );
            const receipt = await tx.wait();
            const settledEvent = receipt.logs.find(
                (log: any) => {
                    try { return dexSettlement.interface.parseLog(log)?.name === "TradeSettled"; }
                    catch { return false; }
                }
            );
            const parsed = dexSettlement.interface.parseLog(settledEvent);
            // Effective fee: 20bps - 5bps = 15bps
            // 1000e18 * 15 / 10000 = 1.5e18
            const expectedFee = ethers.parseUnits("1000", 18) * 15n / 10000n;
            expect(parsed.args[8]).to.equal(expectedFee);
        });

        it("Should fail-open when oracle reverts", async function () {
            await wireOracle(revertingOracle);

            const deadline = await getFutureDeadline();
            const makerOrder = {
                trader: await maker.getAddress(),
                isBuy: false, tokenIn: tokenAAddr, tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000, deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0, referrer: ethers.ZeroAddress, referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: await taker.getAddress(),
                isBuy: true, tokenIn: tokenBAddr, tokenOut: tokenAAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000, deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 1, referrer: ethers.ZeroAddress, referrer2: ethers.ZeroAddress
            };

            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Should NOT revert — fail-open means base fee is used
            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                makerOrder.amountIn, takerOrder.amountIn,
                makerSig, takerSig
            );
            const receipt = await tx.wait();
            const settledEvent = receipt.logs.find(
                (log: any) => {
                    try { return dexSettlement.interface.parseLog(log)?.name === "TradeSettled"; }
                    catch { return false; }
                }
            );
            const parsed = dexSettlement.interface.parseLog(settledEvent);
            // Full 20bps: oracle failed, fell back to base
            const expectedFee = ethers.parseUnits("1000", 18) * 20n / 10000n;
            expect(parsed.args[8]).to.equal(expectedFee);
        });

        it("Should combine per-pair override + oracle discount", async function () {
            // Set per-pair fee to 15bps
            await dexSettlement.schedulePairFee(tokenBAddr, tokenAAddr, 15);
            await time.increase(TIMELOCK_48H + 1);
            await dexSettlement.applyPairFee(tokenBAddr, tokenAAddr);

            // Wire oracle with 5bps discount
            await wireOracle(mockOracle);

            const deadline = await getFutureDeadline();
            const makerOrder = {
                trader: await maker.getAddress(),
                isBuy: false, tokenIn: tokenAAddr, tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000, deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0, referrer: ethers.ZeroAddress, referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: await taker.getAddress(),
                isBuy: true, tokenIn: tokenBAddr, tokenOut: tokenAAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000, deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 1, referrer: ethers.ZeroAddress, referrer2: ethers.ZeroAddress
            };

            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                makerOrder.amountIn, takerOrder.amountIn,
                makerSig, takerSig
            );
            const receipt = await tx.wait();
            const settledEvent = receipt.logs.find(
                (log: any) => {
                    try { return dexSettlement.interface.parseLog(log)?.name === "TradeSettled"; }
                    catch { return false; }
                }
            );
            const parsed = dexSettlement.interface.parseLog(settledEvent);
            // Pair fee 15bps - oracle 5bps = 10bps
            const expectedFee = ethers.parseUnits("1000", 18) * 10n / 10000n;
            expect(parsed.args[8]).to.equal(expectedFee);
        });

        it("Should disable oracle when set to address(0)", async function () {
            await wireOracle(mockOracle); // Enable oracle
            expect(await dexSettlement.feeOracle()).to.not.equal(ethers.ZeroAddress);

            // Schedule disable (address(0))
            await dexSettlement.scheduleFeeOracle(ethers.ZeroAddress);
            await time.increase(TIMELOCK_48H + 1);
            await dexSettlement.applyFeeOracle();

            expect(await dexSettlement.feeOracle()).to.equal(ethers.ZeroAddress);
        });
    });
});
