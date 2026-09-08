/**
 * DEXSettlement V3.1 — Per-Pair Fee Override Tests
 *
 * Tests:
 * - schedulePairFee / applyPairFee / cancelScheduledPairFee
 * - Per-pair override used instead of global fee
 * - Fallback to global when no override set
 * - Timelock enforcement (48h)
 * - MAX_PAIR_FEE enforcement
 * - PendingChangeExists guard
 * - Clearing override (set to 0)
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

describe("DEXSettlement V3.1 — Per-Pair Fee Overrides", function () {
    let dexSettlement: any;
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
    });

    describe("schedulePairFee", function () {
        it("Should schedule a per-pair fee override", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenBAddr, tokenAAddr])
            );
            await expect(
                dexSettlement.schedulePairFee(tokenBAddr, tokenAAddr, 10)
            ).to.emit(dexSettlement, "PairFeeScheduled")
                .withArgs(pairHash, 10, (v: bigint) => v > 0n);
        });

        it("Should revert when fee exceeds MAX_PAIR_FEE (100)", async function () {
            await expect(
                dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 101)
            ).to.be.revertedWithCustomError(dexSettlement, "PairFeeTooHigh");
        });

        it("Should revert when pending change exists", async function () {
            await dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 10);
            await expect(
                dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 15)
            ).to.be.revertedWithCustomError(dexSettlement, "PendingChangeExists");
        });

        it("Should revert when called by non-owner", async function () {
            await expect(
                dexSettlement.connect(nonOwner).schedulePairFee(tokenAAddr, tokenBAddr, 10)
            ).to.be.revertedWithCustomError(dexSettlement, "OwnableUnauthorizedAccount");
        });
    });

    describe("applyPairFee", function () {
        it("Should apply after timelock period", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );
            await dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 10);
            await time.increase(TIMELOCK_48H + 1);

            await expect(
                dexSettlement.applyPairFee(tokenAAddr, tokenBAddr)
            ).to.emit(dexSettlement, "PairFeeApplied")
                .withArgs(pairHash, 0, 10);

            expect(await dexSettlement.pairFeeOverrides(pairHash)).to.equal(10);
        });

        it("Should revert before timelock expires", async function () {
            await dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 10);
            await expect(
                dexSettlement.applyPairFee(tokenAAddr, tokenBAddr)
            ).to.be.revertedWithCustomError(dexSettlement, "TimelockNotElapsed");
        });

        it("Should revert when no pending change", async function () {
            await expect(
                dexSettlement.applyPairFee(tokenAAddr, tokenBAddr)
            ).to.be.revertedWithCustomError(dexSettlement, "NoPendingChange");
        });
    });

    describe("cancelScheduledPairFee", function () {
        it("Should cancel a scheduled pair fee", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );
            await dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 10);
            await expect(
                dexSettlement.cancelScheduledPairFee(tokenAAddr, tokenBAddr)
            ).to.emit(dexSettlement, "PairFeeCancelled").withArgs(pairHash);

            // Can schedule again after cancel
            await dexSettlement.schedulePairFee(tokenAAddr, tokenBAddr, 15);
        });

        it("Should revert when no pending change", async function () {
            await expect(
                dexSettlement.cancelScheduledPairFee(tokenAAddr, tokenBAddr)
            ).to.be.revertedWithCustomError(dexSettlement, "NoPendingChange");
        });
    });

    describe("Per-pair fee in settlement", function () {
        it("Should use per-pair override instead of global fee", async function () {
            // Set per-pair fee to 10bps (vs global 20bps)
            await dexSettlement.schedulePairFee(tokenBAddr, tokenAAddr, 10);
            await time.increase(TIMELOCK_48H + 1);
            await dexSettlement.applyPairFee(tokenBAddr, tokenAAddr);

            // Build and settle a trade
            const deadline = await getFutureDeadline();
            const makerOrder = {
                trader: await maker.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: await taker.getAddress(),
                isBuy: true,
                tokenIn: tokenBAddr,
                tokenOut: tokenAAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 1,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // The fee should be 10bps of takerFillAmount = 1000 * 10/10000 = 1 token
            // (vs 2 tokens at global 20bps)
            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                makerOrder.amountIn, takerOrder.amountIn,
                makerSig, takerSig
            );
            const receipt = await tx.wait();

            // Verify TradeSettled event emitted
            const settledEvent = receipt.logs.find(
                (log: any) => {
                    try {
                        return dexSettlement.interface.parseLog(log)?.name === "TradeSettled";
                    } catch {
                        return false;
                    }
                }
            );
            expect(settledEvent).to.not.be.undefined;

            const parsedEvent = dexSettlement.interface.parseLog(settledEvent);
            // takerFee should be 10bps: 1000e18 * 10 / 10000 = 1e18
            const takerFee = parsedEvent.args[8]; // takerFee + referral
            const expectedFee = ethers.parseUnits("1000", 18) * 10n / 10000n;
            expect(takerFee).to.equal(expectedFee);
        });

        it("Should fall back to global fee when no per-pair override", async function () {
            const deadline = await getFutureDeadline();
            const makerOrder = {
                trader: await maker.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: await taker.getAddress(),
                isBuy: true,
                tokenIn: tokenBAddr,
                tokenOut: tokenAAddr,
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 1,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
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
                    try {
                        return dexSettlement.interface.parseLog(log)?.name === "TradeSettled";
                    } catch {
                        return false;
                    }
                }
            );
            const parsedEvent = dexSettlement.interface.parseLog(settledEvent);
            // Global 20bps: 1000e18 * 20 / 10000 = 2e18
            const takerFee = parsedEvent.args[8];
            const expectedFee = ethers.parseUnits("1000", 18) * 20n / 10000n;
            expect(takerFee).to.equal(expectedFee);
        });

        it("Should clear override when set to 0", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenBAddr, tokenAAddr])
            );
            // Set override to 10
            await dexSettlement.schedulePairFee(tokenBAddr, tokenAAddr, 10);
            await time.increase(TIMELOCK_48H + 1);
            await dexSettlement.applyPairFee(tokenBAddr, tokenAAddr);
            expect(await dexSettlement.pairFeeOverrides(pairHash)).to.equal(10);

            // Clear override (set to 0)
            await dexSettlement.schedulePairFee(tokenBAddr, tokenAAddr, 0);
            await time.increase(TIMELOCK_48H + 1);
            await dexSettlement.applyPairFee(tokenBAddr, tokenAAddr);
            expect(await dexSettlement.pairFeeOverrides(pairHash)).to.equal(0);
        });
    });
});
