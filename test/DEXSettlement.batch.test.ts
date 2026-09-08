/**
 * DEXSettlement V3.1 — Batch Settlement Tests
 *
 * Tests:
 * - Batch of 1/5/20 trades
 * - Partial failure (some trades fail, others succeed)
 * - Empty batch reverts
 * - Oversize batch reverts
 * - Gas comparison: batch vs sequential
 * - Mismatched array lengths revert
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Helper to compute a future deadline based on the current EVM block timestamp.
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

/**
 * Build a matched maker/taker order pair for a full fill
 * @param maker Maker signer
 * @param taker Taker signer
 * @param tokenA Token A address
 * @param tokenB Token B address
 * @param matchingValidator Matching validator address
 * @param amount Trade amount (default: 100 tokens)
 * @param nonce Base nonce (maker uses nonce, taker uses nonce+1)
 * @returns Object with makerOrder and takerOrder
 */
async function buildOrderPair(
    maker: any, taker: any, tokenA: string, tokenB: string,
    matchingValidator: string, amount = ethers.parseUnits("100", 18),
    nonce = 0
) {
    const deadline = await getFutureDeadline();
    const makerOrder = {
        trader: await maker.getAddress(),
        isBuy: false,
        tokenIn: tokenA,
        tokenOut: tokenB,
        amountIn: amount,
        amountOut: amount,
        price: 10000,
        deadline,
        salt: ethers.hexlify(ethers.randomBytes(32)),
        matchingValidator,
        nonce,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress
    };
    const takerOrder = {
        trader: await taker.getAddress(),
        isBuy: true,
        tokenIn: tokenB,
        tokenOut: tokenA,
        amountIn: amount,
        amountOut: amount,
        price: 10000,
        deadline,
        salt: ethers.hexlify(ethers.randomBytes(32)),
        matchingValidator,
        nonce: nonce + 1,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress
    };
    return { makerOrder, takerOrder };
}

describe("DEXSettlement V3.1 — Batch Settlement", function () {
    let dexSettlement: any;
    let _owner: any, maker: any, taker: any, matchingValidator: any;
    let liquidityPool: any, feeVault: any, oddaoTreasury: any;
    let tokenA: any, tokenB: any;
    let matchingValidatorAddress: string;
    const INITIAL_BALANCE = ethers.parseUnits("10000000", 18);

    beforeEach(async function () {
        [_owner, maker, taker, matchingValidator, liquidityPool, feeVault, oddaoTreasury] =
            await ethers.getSigners();
        matchingValidatorAddress = await matchingValidator.getAddress();

        const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
        tokenA = await ERC20Mock.deploy("Token A", "TKA");
        tokenB = await ERC20Mock.deploy("Token B", "TKB");

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

    describe("settleTradesBatch", function () {
        it("Should settle a batch of 1 trade", async function () {
            const tokenAAddr = await tokenA.getAddress();
            const tokenBAddr = await tokenB.getAddress();
            const { makerOrder, takerOrder } = await buildOrderPair(
                maker, taker, tokenAAddr, tokenBAddr, matchingValidatorAddress
            );
            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTradesBatch(
                    [makerOrder], [takerOrder],
                    [makerOrder.amountIn], [takerOrder.amountIn],
                    [makerSig], [takerSig]
                )
            ).to.emit(dexSettlement, "BatchSettlementComplete").withArgs(1, 0);
        });

        it("Should settle a batch of 5 trades", async function () {
            const tokenAAddr = await tokenA.getAddress();
            const tokenBAddr = await tokenB.getAddress();
            const makerOrders = [];
            const takerOrders = [];
            const makerFills = [];
            const takerFills = [];
            const makerSigs = [];
            const takerSigs = [];

            for (let i = 0; i < 5; i++) {
                const { makerOrder, takerOrder } = await buildOrderPair(
                    maker, taker, tokenAAddr, tokenBAddr,
                    matchingValidatorAddress,
                    ethers.parseUnits("10", 18),
                    i * 2
                );
                makerOrders.push(makerOrder);
                takerOrders.push(takerOrder);
                makerFills.push(makerOrder.amountIn);
                takerFills.push(takerOrder.amountIn);
                makerSigs.push(await signOrderEIP712(makerOrder, maker, dexSettlement));
                takerSigs.push(await signOrderEIP712(takerOrder, taker, dexSettlement));
            }

            await expect(
                dexSettlement.settleTradesBatch(
                    makerOrders, takerOrders,
                    makerFills, takerFills,
                    makerSigs, takerSigs
                )
            ).to.emit(dexSettlement, "BatchSettlementComplete").withArgs(5, 0);
        });

        it("Should handle partial failure (2 of 3 succeed)", async function () {
            const tokenAAddr = await tokenA.getAddress();
            const tokenBAddr = await tokenB.getAddress();

            // Good trade 1
            const pair1 = await buildOrderPair(
                maker, taker, tokenAAddr, tokenBAddr,
                matchingValidatorAddress, ethers.parseUnits("10", 18), 0
            );
            // Bad trade: expired deadline
            const pair2 = await buildOrderPair(
                maker, taker, tokenAAddr, tokenBAddr,
                matchingValidatorAddress, ethers.parseUnits("10", 18), 2
            );
            // Force expiry by setting deadline to 0
            pair2.makerOrder.deadline = 1;
            pair2.takerOrder.deadline = 1;

            // Good trade 3
            const pair3 = await buildOrderPair(
                maker, taker, tokenAAddr, tokenBAddr,
                matchingValidatorAddress, ethers.parseUnits("10", 18), 4
            );

            const sig1m = await signOrderEIP712(pair1.makerOrder, maker, dexSettlement);
            const sig1t = await signOrderEIP712(pair1.takerOrder, taker, dexSettlement);
            const sig2m = await signOrderEIP712(pair2.makerOrder, maker, dexSettlement);
            const sig2t = await signOrderEIP712(pair2.takerOrder, taker, dexSettlement);
            const sig3m = await signOrderEIP712(pair3.makerOrder, maker, dexSettlement);
            const sig3t = await signOrderEIP712(pair3.takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTradesBatch(
                    [pair1.makerOrder, pair2.makerOrder, pair3.makerOrder],
                    [pair1.takerOrder, pair2.takerOrder, pair3.takerOrder],
                    [pair1.makerOrder.amountIn, pair2.makerOrder.amountIn, pair3.makerOrder.amountIn],
                    [pair1.takerOrder.amountIn, pair2.takerOrder.amountIn, pair3.takerOrder.amountIn],
                    [sig1m, sig2m, sig3m],
                    [sig1t, sig2t, sig3t]
                )
            ).to.emit(dexSettlement, "BatchSettlementComplete").withArgs(2, 1);
        });

        it("Should revert on empty batch", async function () {
            await expect(
                dexSettlement.settleTradesBatch([], [], [], [], [], [])
            ).to.be.revertedWithCustomError(dexSettlement, "BatchEmpty");
        });

        it("Should revert on oversize batch (>20)", async function () {
            // Build 21 dummy orders — we only need them to trigger the size check
            const dummyOrders = new Array(21).fill({
                trader: ethers.ZeroAddress,
                isBuy: false,
                tokenIn: ethers.ZeroAddress,
                tokenOut: ethers.ZeroAddress,
                amountIn: 0,
                amountOut: 0,
                price: 0,
                deadline: 0,
                salt: ethers.ZeroHash,
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            });
            const fills = new Array(21).fill(0);
            const sigs = new Array(21).fill("0x");

            await expect(
                dexSettlement.settleTradesBatch(
                    dummyOrders, dummyOrders,
                    fills, fills,
                    sigs, sigs
                )
            ).to.be.revertedWithCustomError(dexSettlement, "BatchTooLarge");
        });

        it("Should revert on mismatched array lengths", async function () {
            const tokenAAddr = await tokenA.getAddress();
            const tokenBAddr = await tokenB.getAddress();
            const { makerOrder, takerOrder } = await buildOrderPair(
                maker, taker, tokenAAddr, tokenBAddr, matchingValidatorAddress
            );
            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTradesBatch(
                    [makerOrder, makerOrder], [takerOrder],
                    [makerOrder.amountIn], [takerOrder.amountIn],
                    [makerSig], [takerSig]
                )
            ).to.be.revertedWithCustomError(dexSettlement, "InvalidOrder");
        });

        it("Should reject external call to _settleTradeExternal from non-self", async function () {
            const tokenAAddr = await tokenA.getAddress();
            const tokenBAddr = await tokenB.getAddress();
            const { makerOrder, takerOrder } = await buildOrderPair(
                maker, taker, tokenAAddr, tokenBAddr, matchingValidatorAddress
            );
            const makerSig = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSig = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement._settleTradeExternal(
                    makerOrder, takerOrder,
                    makerOrder.amountIn, takerOrder.amountIn,
                    makerSig, takerSig
                )
            ).to.be.revertedWithCustomError(dexSettlement, "OnlySelf");
        });

        it("Should use less gas per trade in batch vs sequential", async function () {
            const tokenAAddr = await tokenA.getAddress();
            const tokenBAddr = await tokenB.getAddress();

            // Measure sequential: 3 individual settlements
            const seqPairs = [];
            for (let i = 0; i < 3; i++) {
                seqPairs.push(await buildOrderPair(
                    maker, taker, tokenAAddr, tokenBAddr,
                    matchingValidatorAddress,
                    ethers.parseUnits("10", 18), i * 2
                ));
            }

            let seqGas = 0n;
            for (let i = 0; i < 3; i++) {
                const sig1 = await signOrderEIP712(seqPairs[i].makerOrder, maker, dexSettlement);
                const sig2 = await signOrderEIP712(seqPairs[i].takerOrder, taker, dexSettlement);
                const tx = await dexSettlement.settleTrade(
                    seqPairs[i].makerOrder, seqPairs[i].takerOrder,
                    seqPairs[i].makerOrder.amountIn, seqPairs[i].takerOrder.amountIn,
                    sig1, sig2
                );
                const receipt = await tx.wait();
                seqGas += receipt.gasUsed;
            }

            // Measure batch: 3 trades in one call
            const batchMakers = [];
            const batchTakers = [];
            const batchMakerFills = [];
            const batchTakerFills = [];
            const batchMakerSigs = [];
            const batchTakerSigs = [];
            for (let i = 0; i < 3; i++) {
                const pair = await buildOrderPair(
                    maker, taker, tokenAAddr, tokenBAddr,
                    matchingValidatorAddress,
                    ethers.parseUnits("10", 18), 100 + i * 2
                );
                batchMakers.push(pair.makerOrder);
                batchTakers.push(pair.takerOrder);
                batchMakerFills.push(pair.makerOrder.amountIn);
                batchTakerFills.push(pair.takerOrder.amountIn);
                batchMakerSigs.push(await signOrderEIP712(pair.makerOrder, maker, dexSettlement));
                batchTakerSigs.push(await signOrderEIP712(pair.takerOrder, taker, dexSettlement));
            }

            const batchTx = await dexSettlement.settleTradesBatch(
                batchMakers, batchTakers,
                batchMakerFills, batchTakerFills,
                batchMakerSigs, batchTakerSigs
            );
            const batchReceipt = await batchTx.wait();
            const batchGas = batchReceipt.gasUsed;

            // Batch should be cheaper than sequential due to
            // shared base cost (21K saved per additional trade)
            expect(batchGas).to.be.lt(seqGas);
        });
    });
});
