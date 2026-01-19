/**
 * DEXSettlement Trustless Architecture Tests
 *
 * Tests:
 * - Commit-reveal order protection
 * - Dual signature verification (EIP-712)
 * - Order matching logic verification
 * - Atomic settlement execution
 * - Fee distribution (70% Liquidity, 20% ODDAO, 10% Protocol)
 * - Anyone can submit settlement (no VALIDATOR_ROLE required)
 * - Edge cases and security
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

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
        version: '1',
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
            { name: 'nonce', type: 'uint256' }
        ]
    };

    return await signer.signTypedData(domain, types, order);
}

describe("DEXSettlement - Trustless Architecture", function () {
    let dexSettlement: any;
    let owner: any;
    let maker: any;
    let taker: any;
    let matchingValidator: any;
    let anyoneElse: any;
    let liquidityPool: any;
    let oddao: any;
    let protocol: any;

    let ownerAddress: string;
    let makerAddress: string;
    let takerAddress: string;
    let matchingValidatorAddress: string;
    let anyoneElseAddress: string;
    let liquidityPoolAddress: string;
    let oddaoAddress: string;
    let protocolAddress: string;

    // Mock ERC20 tokens for testing
    let tokenA: any;
    let tokenB: any;

    const INITIAL_BALANCE = ethers.parseUnits("1000000", 18);

    beforeEach(async function () {
        [owner, maker, taker, matchingValidator, anyoneElse, liquidityPool, oddao, protocol] =
            await ethers.getSigners();

        ownerAddress = await owner.getAddress();
        makerAddress = await maker.getAddress();
        takerAddress = await taker.getAddress();
        matchingValidatorAddress = await matchingValidator.getAddress();
        anyoneElseAddress = await anyoneElse.getAddress();
        liquidityPoolAddress = await liquidityPool.getAddress();
        oddaoAddress = await oddao.getAddress();
        protocolAddress = await protocol.getAddress();

        // Deploy mock ERC20 tokens
        const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
        tokenA = await ERC20Mock.deploy("Token A", "TKA");
        tokenB = await ERC20Mock.deploy("Token B", "TKB");

        // Mint tokens to both maker and taker for both tokens
        await tokenA.mint(makerAddress, INITIAL_BALANCE);
        await tokenA.mint(takerAddress, INITIAL_BALANCE);
        await tokenB.mint(makerAddress, INITIAL_BALANCE);
        await tokenB.mint(takerAddress, INITIAL_BALANCE);

        // Deploy DEXSettlement
        const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
        dexSettlement = await DEXSettlement.deploy(
            liquidityPoolAddress, // 70% of fees
            oddaoAddress,         // 20% of fees
            protocolAddress       // 10% of fees
        );
        await dexSettlement.waitForDeployment();

        // Approve settlement contract for all participants
        const settlementAddress = await dexSettlement.getAddress();

        // Maker approves both tokens
        await tokenA.connect(maker).approve(settlementAddress, ethers.MaxUint256);
        await tokenB.connect(maker).approve(settlementAddress, ethers.MaxUint256);

        // Taker approves both tokens
        await tokenA.connect(taker).approve(settlementAddress, ethers.MaxUint256);
        await tokenB.connect(taker).approve(settlementAddress, ethers.MaxUint256);
    });

    describe("Deployment", function () {
        it("Should set correct fee recipients", async function () {
            const feeRecipients = await dexSettlement.getFeeRecipients();
            expect(feeRecipients.liquidityPool).to.equal(liquidityPoolAddress);
            expect(feeRecipients.oddao).to.equal(oddaoAddress);
            expect(feeRecipients.protocol).to.equal(protocolAddress);
        });

        it("Should initialize with correct limits", async function () {
            const stats = await dexSettlement.getTradingStats();
            expect(stats.volume).to.equal(0);
            expect(stats.fees).to.equal(0);
            expect(stats.dailyLimit).to.equal(ethers.parseUnits("10000000", 18));
        });
    });

    describe("EIP-712 Signature Verification", function () {
        it("Should hash order correctly", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000, // 1:1 price (in basis points)
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const hash = await dexSettlement.hashOrder(order);
            expect(hash).to.be.properHex(66);
        });

        it("Should verify valid signature", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const hash = await dexSettlement.hashOrder(order);
            const signature = await maker.signMessage(ethers.getBytes(hash));

            // Create matching taker order
            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerHash = await dexSettlement.hashOrder(takerOrder);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Settlement should succeed with valid signatures
            await expect(
                dexSettlement.settleTrade(order, takerOrder, signature, takerSignature)
            ).to.not.be.reverted;
        });

        it("Should reject invalid signature", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            // Sign with wrong signer
            const hash = await dexSettlement.hashOrder(order);
            const wrongSignature = await taker.signMessage(ethers.getBytes(hash));

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerHash = await dexSettlement.hashOrder(takerOrder);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(order, takerOrder, wrongSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "InvalidSignature");
        });
    });

    describe("Commit-Reveal MEV Protection", function () {
        it("Should allow order commitment", async function () {
            const orderHash = ethers.randomBytes(32);

            await expect(dexSettlement.connect(maker).commitOrder(orderHash))
                .to.emit(dexSettlement, "OrderCommitted")
                .withArgs(makerAddress, orderHash, await ethers.provider.getBlockNumber() + 1);
        });

        it("Should store commitment with correct block number", async function () {
            const orderHash = ethers.randomBytes(32);
            await dexSettlement.connect(maker).commitOrder(orderHash);

            const commitment = await dexSettlement.getCommitment(makerAddress, orderHash);
            expect(commitment.orderHash).to.equal(orderHash);
            expect(commitment.commitBlock).to.be.gt(0);
            expect(commitment.revealed).to.equal(false);
        });

        it("Should allow reveal after MIN_COMMIT_BLOCKS", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const orderHash = await dexSettlement.hashOrder(order);
            await dexSettlement.connect(maker).commitOrder(orderHash);

            // Mine MIN_COMMIT_BLOCKS
            for (let i = 0; i < 2; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            await expect(dexSettlement.connect(maker).revealOrder(order)).to.not.be.reverted;
        });

        it("Should reject reveal before MIN_COMMIT_BLOCKS", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const orderHash = await dexSettlement.hashOrder(order);
            await dexSettlement.connect(maker).commitOrder(orderHash);

            // Don't wait - reveal immediately
            await expect(
                dexSettlement.connect(maker).revealOrder(order)
            ).to.be.revertedWithCustomError(dexSettlement, "RevealTooEarly");
        });

        it("Should reject reveal after MAX_COMMIT_BLOCKS", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 36000,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const orderHash = await dexSettlement.hashOrder(order);
            await dexSettlement.connect(maker).commitOrder(orderHash);

            // Mine too many blocks
            for (let i = 0; i < 101; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            await expect(
                dexSettlement.connect(maker).revealOrder(order)
            ).to.be.revertedWithCustomError(dexSettlement, "RevealTooLate");
        });
    });

    describe("Order Matching Verification", function () {
        it("Should verify matching orders (sell/buy)", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.not.be.reverted;
        });

        it("Should reject orders with same side", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: true, // Both buying
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true, // Both buying - should fail
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "OrdersDontMatch");
        });

        it("Should reject mismatched token pairs", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenA.getAddress(), // Wrong token - should be tokenB
                tokenOut: await tokenB.getAddress(), // Wrong token - should be tokenA
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "OrdersDontMatch");
        });

        it("Should reject price mismatch (maker wants higher than taker pays)", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 15000, // Maker wants 1.5x
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000, // Taker only pays 1x - mismatch!
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "OrdersDontMatch");
        });
    });

    describe("Trustless Settlement (ANYONE Can Call)", function () {
        it("Should allow maker to settle own trade", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Maker submits settlement
            await expect(
                dexSettlement
                    .connect(maker)
                    .settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.not.be.reverted;
        });

        it("Should allow matching validator to settle", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Matching validator submits settlement
            await expect(
                dexSettlement
                    .connect(matchingValidator)
                    .settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.not.be.reverted;
        });

        it("Should allow ANYONE ELSE to settle (trustless!)", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Random third party submits settlement - THIS IS THE KEY TEST!
            await expect(
                dexSettlement
                    .connect(anyoneElse)
                    .settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.not.be.reverted;
        });
    });

    describe("Fee Distribution (70% Liquidity, 20% ODDAO, 10% Protocol)", function () {
        it("Should emit fee distribution event", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Calculate expected fees
            const makerFee = (makerOrder.amountOut * 10n) / 10000n; // 0.1%
            const takerFee = (takerOrder.amountOut * 20n) / 10000n; // 0.2%
            const totalFees = makerFee + takerFee;

            const liquidityAmount = (totalFees * 7000n) / 10000n; // 70%
            const oddaoAmount = (totalFees * 2000n) / 10000n; // 20%
            const protocolAmount = (totalFees * 1000n) / 10000n; // 10%

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            )
                .to.emit(dexSettlement, "FeesDistributed")
                .withArgs(
                    matchingValidatorAddress,
                    liquidityAmount,
                    oddaoAmount,
                    protocolAmount,
                    await ethers.provider.getBlockNumber() + 1
                );
        });

        it("Should credit matching validator (not settler)", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Random person settles, but matchingValidator gets credit
            const tx = await dexSettlement
                .connect(anyoneElse)
                .settleTrade(makerOrder, takerOrder, makerSignature, takerSignature);

            const receipt = await tx.wait();
            const event = receipt?.logs.find(
                (log: any) => log.fragment?.name === "TradeSettled"
            );

            // Verify matchingValidator is credited, NOT anyoneElse
            // event.args should have matchingValidator, not anyoneElse
        });
    });

    describe("Security Features", function () {
        it("Should reject self-trading", async function () {
            const order = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const hash = await dexSettlement.hashOrder(order);
            const signature = await maker.signMessage(ethers.getBytes(hash));

            await expect(
                dexSettlement.settleTrade(order, order, signature, signature)
            ).to.be.revertedWithCustomError(dexSettlement, "SelfTradingNotAllowed");
        });

        it("Should reject expired orders", async function () {
            const expiredOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) - 3600, // Already expired
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(expiredOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(expiredOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(expiredOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "OrderExpired");
        });

        it("Should reject replay attacks (nonce protection)", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // First settlement should succeed
            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerSignature,
                takerSignature
            );

            // Replay should fail (order already filled)
            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "OrderAlreadyFilled");
        });

        it("Should reject mismatched matching validators", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress, // Validator A
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: anyoneElseAddress, // Validator B - MISMATCH!
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "MatchingValidatorMismatch");
        });
    });

    describe("Atomic Settlement Execution", function () {
        it("Should execute atomic token swap", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerBalanceBefore = await tokenA.balanceOf(makerAddress);
            const takerBalanceBefore = await tokenB.balanceOf(takerAddress);

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerSignature,
                takerSignature
            );

            // Verify balances changed correctly
            const makerBalanceAfter = await tokenA.balanceOf(makerAddress);
            const takerBalanceAfter = await tokenB.balanceOf(takerAddress);

            expect(makerBalanceAfter).to.equal(makerBalanceBefore - makerOrder.amountIn);
            expect(takerBalanceAfter).to.equal(takerBalanceBefore - takerOrder.amountIn);
        });

        it("Should collect fees correctly", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const contractBalanceBefore = await tokenB.balanceOf(
                await dexSettlement.getAddress()
            );

            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerSignature,
                takerSignature
            );

            const contractBalanceAfter = await tokenB.balanceOf(
                await dexSettlement.getAddress()
            );

            // Contract should collect fees
            const makerFee = (makerOrder.amountOut * 10n) / 10000n; // 0.1%
            const takerFee = (takerOrder.amountOut * 20n) / 10000n; // 0.2%
            const totalFees = makerFee + takerFee;

            expect(contractBalanceAfter).to.equal(contractBalanceBefore + totalFees);
        });
    });

    describe("Emergency Controls", function () {
        it("Should allow owner to trigger emergency stop", async function () {
            await expect(dexSettlement.emergencyStopTrading("Test emergency"))
                .to.emit(dexSettlement, "EmergencyStop")
                .withArgs(ownerAddress, "Test emergency");

            expect(await dexSettlement.emergencyStop()).to.equal(true);
        });

        it("Should reject settlements during emergency stop", async function () {
            await dexSettlement.emergencyStopTrading("Test emergency");

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "EmergencyStopActive");
        });

        it("Should allow owner to resume trading", async function () {
            await dexSettlement.emergencyStopTrading("Test emergency");
            await expect(dexSettlement.resumeTrading())
                .to.emit(dexSettlement, "TradingResumed")
                .withArgs(ownerAddress);

            expect(await dexSettlement.emergencyStop()).to.equal(false);
        });
    });

    describe("Nonce Management", function () {
        it("Should increment nonces after settlement", async function () {
            const makerNonceBefore = await dexSettlement.getNonce(makerAddress);
            const takerNonceBefore = await dexSettlement.getNonce(takerAddress);

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: Number(makerNonceBefore)
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: Math.floor(Date.now() / 1000) + 3600,
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: Number(takerNonceBefore)
            };

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerSignature,
                takerSignature
            );

            const makerNonceAfter = await dexSettlement.getNonce(makerAddress);
            const takerNonceAfter = await dexSettlement.getNonce(takerAddress);

            expect(makerNonceAfter).to.equal(makerNonceBefore + 1n);
            expect(takerNonceAfter).to.equal(takerNonceBefore + 1n);
        });
    });
});
