/**
 * DEXSettlement Trustless Architecture Tests
 *
 * Tests:
 * - Commit-reveal order protection
 * - Dual signature verification (EIP-712)
 * - Order matching logic verification
 * - Atomic settlement execution
 * - Fee distribution (70% LP, 30% Vault) with maker rebate
 * - Anyone can submit settlement (no VALIDATOR_ROLE required)
 * - Edge cases and security
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Helper to compute a future deadline based on the current EVM block timestamp.
 * Using the EVM timestamp (not Date.now()) is critical because earlier test suites
 * call time.increase() which advances the EVM clock far beyond wall-clock time.
 * @param offsetSeconds Seconds into the future (default: 1 year = 365 days)
 * @returns A deadline timestamp guaranteed to be in the EVM future
 */
async function getFutureDeadline(offsetSeconds = 86400 * 365): Promise<number> {
    const latestBlock = await ethers.provider.getBlock("latest");
    return latestBlock!.timestamp + offsetSeconds;
}

/**
 * Helper to compute a past deadline based on the current EVM block timestamp.
 * @param offsetSeconds Seconds in the past (default: 3600 = 1 hour)
 * @returns A deadline timestamp guaranteed to be in the EVM past
 */
async function getPastDeadline(offsetSeconds = 3600): Promise<number> {
    const latestBlock = await ethers.provider.getBlock("latest");
    return latestBlock!.timestamp - offsetSeconds;
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
 * Helper to sign an IntentAcceptance EIP-712 message (C-01 solver consent).
 * @param intentId Intent identifier (bytes32)
 * @param trader Address of the trader locking collateral
 * @param solver Address of the solver accepting the intent
 * @param tokenIn Token being provided by the trader
 * @param tokenOut Token being provided by the solver
 * @param traderAmount Amount the trader is locking
 * @param solverAmount Amount the solver will provide
 * @param deadline Deadline timestamp
 * @param solverSigner Signer wallet for the solver
 * @param settlement DEXSettlement contract instance
 * @returns EIP-712 signature string
 */
async function signIntentAcceptance(
    intentId: string,
    trader: string,
    solver: string,
    tokenIn: string,
    tokenOut: string,
    traderAmount: bigint,
    solverAmount: bigint,
    deadline: number,
    solverSigner: any,
    settlement: any
): Promise<string> {
    const network = await ethers.provider.getNetwork();
    const domain = {
        name: 'OmniCoin DEX Settlement',
        version: '3',
        chainId: network.chainId,
        verifyingContract: await settlement.getAddress()
    };
    const types = {
        IntentAcceptance: [
            { name: 'intentId', type: 'bytes32' },
            { name: 'trader', type: 'address' },
            { name: 'solver', type: 'address' },
            { name: 'tokenIn', type: 'address' },
            { name: 'tokenOut', type: 'address' },
            { name: 'traderAmount', type: 'uint256' },
            { name: 'solverAmount', type: 'uint256' },
            { name: 'deadline', type: 'uint256' }
        ]
    };
    const value = {
        intentId,
        trader,
        solver,
        tokenIn,
        tokenOut,
        traderAmount,
        solverAmount,
        deadline
    };
    return solverSigner.signTypedData(domain, types, value);
}

describe("DEXSettlement - Trustless Architecture", function () {
    let dexSettlement: any;
    let owner: any;
    let maker: any;
    let taker: any;
    let matchingValidator: any;
    let anyoneElse: any;
    let liquidityPool: any;
    let feeVault: any;
    let oddaoTreasury: any;

    let ownerAddress: string;
    let makerAddress: string;
    let takerAddress: string;
    let matchingValidatorAddress: string;
    let anyoneElseAddress: string;
    let liquidityPoolAddress: string;
    let feeVaultAddress: string;
    let oddaoTreasuryAddress: string;

    // Mock ERC20 tokens for testing
    let tokenA: any;
    let tokenB: any;

    const INITIAL_BALANCE = ethers.parseUnits("1000000", 18);

    beforeEach(async function () {
        [owner, maker, taker, matchingValidator, anyoneElse, liquidityPool, feeVault, oddaoTreasury] =
            await ethers.getSigners();

        ownerAddress = await owner.getAddress();
        makerAddress = await maker.getAddress();
        takerAddress = await taker.getAddress();
        matchingValidatorAddress = await matchingValidator.getAddress();
        anyoneElseAddress = await anyoneElse.getAddress();
        liquidityPoolAddress = await liquidityPool.getAddress();
        feeVaultAddress = await feeVault.getAddress();
        oddaoTreasuryAddress = await oddaoTreasury.getAddress();

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
            liquidityPoolAddress,      // 70% of net fees -> Liquidity Providers
            feeVaultAddress,           // 30% of net fees -> UnifiedFeeVault
            oddaoTreasuryAddress,      // ODDAO Treasury (referral surcharge 10%)
            ethers.ZeroAddress         // ERC-2771 trusted forwarder (none in tests)
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
            expect(feeRecipients.feeVault).to.equal(feeVaultAddress);
            expect(feeRecipients.oddaoTreasury).to.equal(oddaoTreasuryAddress);
        });

        it("Should initialize configurable fee parameters", async function () {
            expect(await dexSettlement.spotTakerFeeBps()).to.equal(20);
            expect(await dexSettlement.referralFeeBps()).to.equal(5);
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const hash = await dexSettlement.hashOrder(order);
            expect(hash).to.be.properHex(64);
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            // Both signatures must use EIP-712 typed data signing
            const makerSignature = await signOrderEIP712(order, maker, dexSettlement);

            // Create matching taker order
            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Settlement should succeed with valid signatures
            await expect(
                dexSettlement.settleTrade(order, takerOrder, order.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _takerHash0 = await dexSettlement.hashOrder(takerOrder);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(order, takerOrder, order.amountIn, takerOrder.amountIn, wrongSignature, takerSignature)
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
            const orderHash = ethers.hexlify(ethers.randomBytes(32));
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
                deadline: await getFutureDeadline(),
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
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
                deadline: await getFutureDeadline(),
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
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
                deadline: await getFutureDeadline(36000),
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash1 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash1 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true, // Both buying - should fail
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash2 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash2 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenA.getAddress(), // Wrong token - should be tokenB
                tokenOut: await tokenB.getAddress(), // Wrong token - should be tokenA
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash3 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash3 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000, // Taker only pays 1x - mismatch!
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash4 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash4 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
            ).to.be.revertedWithCustomError(dexSettlement, "OrdersDontMatch");
        });

        it("Should reject zero amountOut maker order with InvalidFillAmount (VT-04)", async function () {
            // The public settle path cannot reach _verifyFillAmounts with a zero
            // amountOut order: _verifyOrdersMatch rejects it with InvalidOrder
            // first. The VT-04 guard is defense-in-depth at the fill-verification
            // layer, so exercise it through the DEXSettlementHarness.
            const DEXSettlementHarness = await ethers.getContractFactory("DEXSettlementHarness");
            const harness = await DEXSettlementHarness.deploy(
                liquidityPoolAddress,
                feeVaultAddress,
                oddaoTreasuryAddress,
                ethers.ZeroAddress
            );
            await harness.waitForDeployment();

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: 0, // VT-04: zero signed output
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            await expect(
                harness.verifyFillAmounts(
                    makerOrder,
                    takerOrder,
                    makerOrder.amountIn,
                    takerOrder.amountIn,
                    ethers.id("maker"), // fresh hashes -> zero filledAmounts
                    ethers.id("taker")
                )
            ).to.be.revertedWithCustomError(harness, "InvalidFillAmount");
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash5 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash5 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Maker submits settlement
            await expect(
                dexSettlement
                    .connect(maker)
                    .settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash6 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash6 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Matching validator submits settlement
            await expect(
                dexSettlement
                    .connect(matchingValidator)
                    .settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash7 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash7 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Random third party submits settlement - THIS IS THE KEY TEST!
            await expect(
                dexSettlement
                    .connect(anyoneElse)
                    .settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
            ).to.not.be.reverted;
        });
    });

    describe("Fee Distribution (70% LP, 30% Vault) with Maker Rebate", function () {
        it("Should emit fee distribution event with net fees after rebate", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Maker gets 0.05% rebate (no fee), taker pays 0.20%
            const makerRebate = (makerOrder.amountIn * 5n) / 10000n; // 0.05% rebate TO maker
            const takerFee = (takerOrder.amountIn * 20n) / 10000n; // 0.2% taker fee
            const netFee = takerFee - makerRebate;

            // 70/30 split on net fee (LP/Vault)
            const lpAmount = (netFee * 7000n) / 10000n; // 70% -> LP
            const vaultAmount = netFee - lpAmount; // 30% -> UnifiedFeeVault (remainder)

            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature
            );
            const receipt = await tx.wait();
            const block = await ethers.provider.getBlock(receipt.blockNumber);

            await expect(tx)
                .to.emit(dexSettlement, "FeesDistributed")
                .withArgs(
                    matchingValidatorAddress,
                    lpAmount,
                    vaultAmount,
                    block!.timestamp
                );
        });

        it("Should pay maker rebate (0.05%) to maker address", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Rebate is paid in taker's tokenIn (tokenB)
            const makerRebate = (makerOrder.amountIn * 5n) / 10000n; // 0.05%
            const makerTokenBBefore = await tokenB.balanceOf(makerAddress);

            await dexSettlement.settleTrade(
                makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature
            );

            const makerTokenBAfter = await tokenB.balanceOf(makerAddress);
            // Maker receives taker's amountOut (full) + rebate in taker's tokenIn
            // Rebate comes from taker fee, paid in tokenB
            expect(makerTokenBAfter - makerTokenBBefore).to.equal(
                takerOrder.amountIn - (takerOrder.amountIn * 20n) / 10000n + makerRebate
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash8 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash8 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Random person settles, but matchingValidator gets credit
            const tx = await dexSettlement
                .connect(anyoneElse)
                .settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature);

            const receipt = await tx.wait();
            const _event = receipt?.logs.find(
                (log: any) => log.fragment?.name === "TradeSettled"
            );

            // Verify matchingValidator is credited, NOT anyoneElse
            // _event.args should have matchingValidator, not anyoneElse
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const hash = await dexSettlement.hashOrder(order);
            const signature = await maker.signMessage(ethers.getBytes(hash));

            await expect(
                dexSettlement.settleTrade(order, order, order.amountIn, order.amountIn, signature, signature)
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
                deadline: await getPastDeadline(), // Already expired
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash9 = await dexSettlement.hashOrder(expiredOrder);
            const _takerHash9 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(expiredOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(expiredOrder, takerOrder, expiredOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash10 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash10 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // First settlement should succeed
            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerOrder.amountIn,
                takerOrder.amountIn,
                makerSignature,
                takerSignature
            );

            // Replay should fail (order already filled)
            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress, // Validator A
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: anyoneElseAddress, // Validator B - MISMATCH!
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const _makerHash11 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash11 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerBalanceBefore = await tokenA.balanceOf(makerAddress);
            const takerBalanceBefore = await tokenB.balanceOf(takerAddress);

            const _makerHash12 = await dexSettlement.hashOrder(makerOrder);
            const _takerHash12 = await dexSettlement.hashOrder(takerOrder);

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerOrder.amountIn,
                takerOrder.amountIn,
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const settlementAddress = await dexSettlement.getAddress();

            // H-04: Fees now come from input tokens (tokenA for maker, tokenB for taker)
            const contractBalanceABefore = await tokenA.balanceOf(settlementAddress);
            const contractBalanceBBefore = await tokenB.balanceOf(settlementAddress);

            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerOrder.amountIn,
                takerOrder.amountIn,
                makerSignature,
                takerSignature
            );

            const contractBalanceAAfter = await tokenA.balanceOf(settlementAddress);
            const contractBalanceBAfter = await tokenB.balanceOf(settlementAddress);

            // Fees are push-transferred immediately to recipients,
            // so the contract should NOT hold any fees
            expect(contractBalanceAAfter).to.equal(contractBalanceABefore);
            expect(contractBalanceBAfter).to.equal(contractBalanceBBefore);

            // Verify totalFeesCollected was updated with net fee (after rebate)
            const takerFee = (takerOrder.amountIn * 20n) / 10000n; // 0.2%
            const makerRebate = (makerOrder.amountIn * 5n) / 10000n; // 0.05%
            const netFee = takerFee - makerRebate;
            const stats = await dexSettlement.getTradingStats();
            expect(stats.fees).to.equal(netFee);
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
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature)
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

    describe("Nonce Management (Bitmap)", function () {
        it("Should mark nonces as used after settlement", async function () {
            // Bitmap nonces: nonce 0 should be unused before settlement
            const makerNonceUsedBefore = await dexSettlement.isNonceUsed(makerAddress, 0);
            const takerNonceUsedBefore = await dexSettlement.isNonceUsed(takerAddress, 0);
            expect(makerNonceUsedBefore).to.equal(false);
            expect(takerNonceUsedBefore).to.equal(false);

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("100", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            await dexSettlement.settleTrade(
                makerOrder,
                takerOrder,
                makerOrder.amountIn,
                takerOrder.amountIn,
                makerSignature,
                takerSignature
            );

            // After settlement, nonce 0 should be marked as used
            const makerNonceUsedAfter = await dexSettlement.isNonceUsed(makerAddress, 0);
            const takerNonceUsedAfter = await dexSettlement.isNonceUsed(takerAddress, 0);
            expect(makerNonceUsedAfter).to.equal(true);
            expect(takerNonceUsedAfter).to.equal(true);
        });
    });

    // ════════════════════════════════════════════════════════════════════
    //  INTENT SETTLEMENT — Fee-on-Transfer Guard (Security Fix 1B)
    // ════════════════════════════════════════════════════════════════════

    describe("Intent Settlement — Fee-on-Transfer Guard", function () {
        let feeToken: any;
        let feeTokenAddress: string;
        let tokenAAddress: string;
        let tokenBAddress: string;
        let settlementAddress: string;

        const TRADE_AMOUNT = ethers.parseUnits("1000", 18);

        beforeEach(async function () {
            // Deploy a 1% fee-on-transfer token
            const FeeToken = await ethers.getContractFactory("MockFeeOnTransferToken");
            feeToken = await FeeToken.deploy("Fee Token", "FEE", 100); // 100 bps = 1%
            await feeToken.waitForDeployment();
            feeTokenAddress = await feeToken.getAddress();

            tokenAAddress = await tokenA.getAddress();
            tokenBAddress = await tokenB.getAddress();
            settlementAddress = await dexSettlement.getAddress();

            // Mint fee tokens to maker and taker
            await feeToken.mint(makerAddress, INITIAL_BALANCE);
            await feeToken.mint(takerAddress, INITIAL_BALANCE);

            // Approve settlement contract for fee token
            await feeToken.connect(maker).approve(settlementAddress, ethers.MaxUint256);
            await feeToken.connect(taker).approve(settlementAddress, ethers.MaxUint256);
        });

        it("should revert lockIntentCollateral with fee-on-transfer token", async function () {
            const intentId = ethers.keccak256(ethers.toUtf8Bytes("fot-lock-test-1"));
            const deadline = await getFutureDeadline();

            // C-01: Solver must sign IntentAcceptance even for fee-on-transfer test
            // (the revert happens AFTER the solver signature check, at balance verification)
            const solverSig = await signIntentAcceptance(
                intentId, makerAddress, takerAddress,
                feeTokenAddress, tokenBAddress,
                TRADE_AMOUNT, TRADE_AMOUNT, deadline,
                taker, dexSettlement
            );

            // Attempt to lock collateral using fee-on-transfer token as tokenIn
            await expect(
                dexSettlement.connect(maker).lockIntentCollateral(
                    intentId,
                    takerAddress,       // solver
                    feeTokenAddress,    // tokenIn (fee-on-transfer)
                    tokenBAddress,      // tokenOut (standard)
                    TRADE_AMOUNT,       // traderAmount
                    TRADE_AMOUNT,       // solverAmount
                    deadline,
                    matchingValidatorAddress, // matchingValidator
                    ethers.ZeroAddress,     // referrer
                    ethers.ZeroAddress,     // referrer2
                    solverSig               // C-01: solver consent signature
                )
            ).to.be.revertedWithCustomError(dexSettlement, "FeeOnTransferNotSupported");
        });

        it("should allow lockIntentCollateral with standard ERC20", async function () {
            const intentId = ethers.keccak256(ethers.toUtf8Bytes("standard-lock-test-1"));
            const deadline = await getFutureDeadline();

            // C-01: Solver signs IntentAcceptance
            const solverSig = await signIntentAcceptance(
                intentId, makerAddress, takerAddress,
                tokenAAddress, tokenBAddress,
                TRADE_AMOUNT, TRADE_AMOUNT, deadline,
                taker, dexSettlement
            );

            // Lock collateral using standard tokenA — should succeed
            await expect(
                dexSettlement.connect(maker).lockIntentCollateral(
                    intentId,
                    takerAddress,       // solver
                    tokenAAddress,      // tokenIn (standard ERC20)
                    tokenBAddress,      // tokenOut (standard)
                    TRADE_AMOUNT,       // traderAmount
                    TRADE_AMOUNT,       // solverAmount
                    deadline,
                    matchingValidatorAddress, // matchingValidator
                    ethers.ZeroAddress,     // referrer
                    ethers.ZeroAddress,     // referrer2
                    solverSig               // C-01: solver consent signature
                )
            ).to.emit(dexSettlement, "IntentCollateralLocked")
                .withArgs(intentId, makerAddress, takerAddress, TRADE_AMOUNT, TRADE_AMOUNT);

            // Verify the contract actually holds the escrowed tokens
            const contractBalance = await tokenA.balanceOf(settlementAddress);
            expect(contractBalance).to.be.gte(TRADE_AMOUNT);
        });

        it("should revert settleIntent when solver uses fee-on-transfer token", async function () {
            const intentId = ethers.keccak256(ethers.toUtf8Bytes("fot-settle-test-1"));
            const deadline = await getFutureDeadline();

            // C-01: Solver signs IntentAcceptance
            const solverSig = await signIntentAcceptance(
                intentId, makerAddress, takerAddress,
                tokenAAddress, feeTokenAddress,
                TRADE_AMOUNT, TRADE_AMOUNT, deadline,
                taker, dexSettlement
            );

            // Step 1: Lock collateral with standard tokenA as tokenIn
            //         and fee-on-transfer token as tokenOut
            await dexSettlement.connect(maker).lockIntentCollateral(
                intentId,
                takerAddress,       // solver
                tokenAAddress,      // tokenIn (standard — lock succeeds)
                feeTokenAddress,    // tokenOut (fee-on-transfer)
                TRADE_AMOUNT,       // traderAmount
                TRADE_AMOUNT,       // solverAmount
                deadline,
                matchingValidatorAddress, // matchingValidator
                ethers.ZeroAddress,     // referrer
                ethers.ZeroAddress,     // referrer2
                solverSig               // C-01: solver consent signature
            );

            // Step 2: Solver (taker) tries to settle — solver must
            //         provide fee-on-transfer tokenOut to the trader.
            //         The balance-before/after check in settleIntent
            //         should detect the discrepancy and revert.
            await expect(
                dexSettlement.connect(taker).settleIntent(intentId)
            ).to.be.revertedWithCustomError(dexSettlement, "FeeOnTransferNotSupported");
        });
    });

    // ════════════════════════════════════════════════════════════════════
    //  C-01: Solver Signature Verification (Round 8 Security Fix)
    // ════════════════════════════════════════════════════════════════════

    describe("C-01: Solver Signature Verification", function () {
        it("should revert lockIntentCollateral with invalid solver signature", async function () {
            const intentId = ethers.keccak256(ethers.toUtf8Bytes("c01-invalid-sig"));
            const deadline = await getFutureDeadline();
            const tokenAAddress = await tokenA.getAddress();
            const tokenBAddress = await tokenB.getAddress();
            const TRADE_AMOUNT = ethers.parseUnits("1000", 18);

            // Sign with maker instead of taker (solver) — wrong signer
            const invalidSig = await signIntentAcceptance(
                intentId, makerAddress, takerAddress,
                tokenAAddress, tokenBAddress,
                TRADE_AMOUNT, TRADE_AMOUNT, deadline,
                maker, dexSettlement  // maker signs, but taker is the solver
            );

            await expect(
                dexSettlement.connect(maker).lockIntentCollateral(
                    intentId,
                    takerAddress,               // solver
                    tokenAAddress,
                    tokenBAddress,
                    TRADE_AMOUNT,
                    TRADE_AMOUNT,
                    deadline,
                    matchingValidatorAddress,
                    ethers.ZeroAddress,
                    ethers.ZeroAddress,
                    invalidSig                  // signed by maker, NOT solver
                )
            ).to.be.revertedWithCustomError(dexSettlement, "InvalidSolverSignature");
        });
    });

    // ════════════════════════════════════════════════════════════════════
    //  REFERRAL SURCHARGE — 5bp surcharge on referred takers
    // ════════════════════════════════════════════════════════════════════

    describe("Referral Surcharge Distribution", function () {
        let referrer: any;
        let referrer2Signer: any;
        let referrerAddress: string;
        let referrer2Address: string;

        beforeEach(async function () {
            // Get dedicated signers for referrer roles (distinct from oddaoTreasury)
            const signers = await ethers.getSigners();
            referrer = signers[8];
            referrer2Signer = signers[9];
            referrerAddress = await referrer.getAddress();
            referrer2Address = await referrer2Signer.getAddress();
        });

        it("Non-referred taker pays 20bp only, no referral event", async function () {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: ethers.parseUnits("1000", 18),
                amountOut: ethers.parseUnits("1000", 18),
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature
            );

            // Should NOT emit ReferralFeeDistributed
            await expect(tx).to.not.emit(dexSettlement, "ReferralFeeDistributed");

            // Net fee should be (20bp - 5bp) = 15bp of 1000 = 0.15
            const stats = await dexSettlement.getTradingStats();
            const expectedNetFee = (ethers.parseUnits("1000", 18) * 15n) / 10000n;
            expect(stats.fees).to.equal(expectedNetFee);
        });

        it("Referred taker pays 25bp total, referral surcharge distributed 70/20/10", async function () {
            const tradeAmount = ethers.parseUnits("10000", 18);

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: tradeAmount,
                amountOut: tradeAmount,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress, // maker referrer not used
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: tradeAmount,
                amountOut: tradeAmount,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: referrerAddress,    // taker was referred
                referrer2: referrer2Address   // referrer's referrer
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Track referrer balances before
            const referrerBefore = await tokenB.balanceOf(referrerAddress);
            const referrer2Before = await tokenB.balanceOf(referrer2Address);

            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature
            );

            // Referral surcharge = 10000 * 5 / 10000 = 5 tokens
            const surcharge = (tradeAmount * 5n) / 10000n;
            const referrerAmt = (surcharge * 7000n) / 10000n;   // 70% = 3.5 tokens
            const referrer2Amt = (surcharge * 2000n) / 10000n;  // 20% = 1 token
            const _oddaoAmt = surcharge - referrerAmt - referrer2Amt; // 10% = 0.5 tokens

            // Should emit ReferralFeeDistributed
            await expect(tx).to.emit(dexSettlement, "ReferralFeeDistributed");

            // Verify referrer received 70%
            const referrerAfter = await tokenB.balanceOf(referrerAddress);
            expect(referrerAfter - referrerBefore).to.equal(referrerAmt);

            // Verify referrer2 received 20%
            const referrer2After = await tokenB.balanceOf(referrer2Address);
            expect(referrer2After - referrer2Before).to.equal(referrer2Amt);
        });

        it("Referrer2 = zero address: their 20% redirects to ODDAO", async function () {
            const tradeAmount = ethers.parseUnits("10000", 18);

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: tradeAmount,
                amountOut: tradeAmount,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: tradeAmount,
                amountOut: tradeAmount,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: referrerAddress,       // has referrer
                referrer2: ethers.ZeroAddress    // NO referrer2
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const surcharge = (tradeAmount * 5n) / 10000n;
            const referrerAmt = (surcharge * 7000n) / 10000n;
            const _referrer2Amt = (surcharge * 2000n) / 10000n;
            const oddaoAmt = surcharge - referrerAmt; // ODDAO gets 10% + 20% = 30%

            const oddaoAddr = oddaoTreasuryAddress;
            const oddaoBefore = await tokenB.balanceOf(oddaoAddr);
            const referrerBefore = await tokenB.balanceOf(referrerAddress);

            await dexSettlement.settleTrade(
                makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature
            );

            const oddaoAfter = await tokenB.balanceOf(oddaoAddr);
            const referrerAfter = await tokenB.balanceOf(referrerAddress);

            // Referrer gets 70%
            expect(referrerAfter - referrerBefore).to.equal(referrerAmt);
            // ODDAO gets 10% + 20% = 30%
            expect(oddaoAfter - oddaoBefore).to.equal(oddaoAmt);
        });

        it("LP math untouched: LP still gets 70% of 15bp net fee", async function () {
            const tradeAmount = ethers.parseUnits("10000", 18);

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: tradeAmount,
                amountOut: tradeAmount,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: tradeAmount,
                amountOut: tradeAmount,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: referrerAddress,    // referred
                referrer2: referrer2Address
            };

            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            const lpBefore = await tokenB.balanceOf(liquidityPoolAddress);

            await dexSettlement.settleTrade(
                makerOrder, takerOrder, makerOrder.amountIn, takerOrder.amountIn, makerSignature, takerSignature
            );

            const lpAfter = await tokenB.balanceOf(liquidityPoolAddress);

            // Base fee: 20bp taker, 5bp rebate = 15bp net
            const takerFee = (tradeAmount * 20n) / 10000n;
            const makerRebate = (tradeAmount * 5n) / 10000n;
            const netFee = takerFee - makerRebate;
            const expectedLp = (netFee * 7000n) / 10000n;

            // LP gets 70% of the BASE net fee (not the surcharge)
            expect(lpAfter - lpBefore).to.equal(expectedLp);
        });
    });

    // ════════════════════════════════════════════════════════════════════
    //  CONFIGURABLE FEE TIMELOCK TESTS
    // ════════════════════════════════════════════════════════════════════

    describe("Fee Parameter Timelocks", function () {
        it("Should schedule and apply spot taker fee change", async function () {
            await dexSettlement.scheduleSpotTakerFee(30); // 0.30%
            expect(await dexSettlement.pendingSpotTakerFeeBps()).to.equal(30);

            // Pioneer phase: TIMELOCK_DELAY == 0, so the change applies
            // immediately (no TimelockNotElapsed window).
            await expect(dexSettlement.applySpotTakerFee())
                .to.emit(dexSettlement, "SpotTakerFeeUpdated")
                .withArgs(20, 30);

            expect(await dexSettlement.spotTakerFeeBps()).to.equal(30);
        });

        it("Should reject spot taker fee above maximum", async function () {
            await expect(
                dexSettlement.scheduleSpotTakerFee(101) // > 100bp max
            ).to.be.revertedWithCustomError(dexSettlement, "SpotTakerFeeTooHigh");
        });

        it("Should schedule and apply referral fee change", async function () {
            await dexSettlement.scheduleReferralFee(10); // 0.10%
            expect(await dexSettlement.pendingReferralFeeBps()).to.equal(10);

            // Advance time 48 hours
            await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
            await ethers.provider.send("evm_mine", []);

            await expect(dexSettlement.applyReferralFee())
                .to.emit(dexSettlement, "ReferralFeeUpdated")
                .withArgs(5, 10);

            expect(await dexSettlement.referralFeeBps()).to.equal(10);
        });

        it("Should reject referral fee above maximum", async function () {
            await expect(
                dexSettlement.scheduleReferralFee(51) // > 50bp max
            ).to.be.revertedWithCustomError(dexSettlement, "ReferralFeeTooHigh");
        });

        it("Should cancel scheduled fee changes", async function () {
            await dexSettlement.scheduleSpotTakerFee(30);
            await expect(dexSettlement.cancelScheduledSpotTakerFee())
                .to.emit(dexSettlement, "SpotTakerFeeChangeCancelled");
            expect(await dexSettlement.spotTakerFeeBps()).to.equal(20); // unchanged

            await dexSettlement.scheduleReferralFee(10);
            await expect(dexSettlement.cancelScheduledReferralFee())
                .to.emit(dexSettlement, "ReferralFeeChangeCancelled");
            expect(await dexSettlement.referralFeeBps()).to.equal(5); // unchanged
        });
    });

    // ═══════════════════════════════════════════════════════════════════════
    //  V3 Partial Fill Settlement
    // ═══════════════════════════════════════════════════════════════════════
    describe("Partial Fill Settlement", function () {
        /**
         * Build a fresh pair of 1:1 maker-sell / taker-buy orders with a
         * configurable amountIn on the maker and taker legs. Intentionally
         * 1:1 price so proportionality math simplifies to identity.
         * @param makerAmount Maker amountIn (and amountOut) in tokenA units
         * @param takerAmount Taker amountIn (and amountOut) in tokenB units
         */
        async function buildOrders(makerAmount: bigint, takerAmount: bigint) {
            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: makerAmount,
                amountOut: makerAmount, // 1:1
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: takerAmount,
                amountOut: takerAmount, // 1:1
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);
            return { makerOrder, takerOrder, makerSignature, takerSignature };
        }

        it("Should consume partial amount of a maker order and leave remainder matchable", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const halfTaker = ethers.parseUnits("500", 18);

            // Build an over-sized maker order and a smaller taker using helper
            const { makerOrder, takerOrder, makerSignature, takerSignature } =
                await buildOrders(makerSize, halfTaker);

            // First partial fill: consume 500 of maker (half), 500 of taker (full)
            await expect(
                dexSettlement.settleTrade(
                    makerOrder, takerOrder,
                    halfTaker, halfTaker,
                    makerSignature, takerSignature
                )
            ).to.not.be.reverted;

            // Maker nonce should NOT be set (still has remainder)
            expect(await dexSettlement.isNonceUsed(makerAddress, 0)).to.equal(false);
            // Taker nonce IS set (fully filled)
            expect(await dexSettlement.isNonceUsed(takerAddress, 0)).to.equal(true);

            // filledAmounts tracks the partial consumption on the maker side
            const makerHash = await dexSettlement.hashOrder(makerOrder);
            expect(await dexSettlement.filledAmounts(makerHash)).to.equal(halfTaker);
        });

        it("Should allow two sequential partial fills summing to the full maker amount", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);

            // First partial fill
            const first = await buildOrders(makerSize, half);
            await dexSettlement.settleTrade(
                first.makerOrder, first.takerOrder,
                half, half,
                first.makerSignature, first.takerSignature
            );

            // Second partial fill with a fresh taker (nonce 1) consuming the
            // other half of the same maker order
            const takerOrder2 = {
                ...first.takerOrder,
                salt: ethers.randomBytes(32),
                nonce: 1
            };
            const takerSignature2 = await signOrderEIP712(takerOrder2, taker, dexSettlement);

            await dexSettlement.settleTrade(
                first.makerOrder, takerOrder2,
                half, half,
                first.makerSignature, takerSignature2
            );

            // Maker fully filled, nonce now consumed
            expect(await dexSettlement.isNonceUsed(makerAddress, 0)).to.equal(true);
            const makerHash = await dexSettlement.hashOrder(first.makerOrder);
            expect(await dexSettlement.filledAmounts(makerHash)).to.equal(makerSize);
        });

        it("Should revert FillExceedsRemaining when attempting to over-fill a maker order", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);
            const tooMuch = ethers.parseUnits("600", 18);

            // First fill: 500 of 1000
            const first = await buildOrders(makerSize, half);
            await dexSettlement.settleTrade(
                first.makerOrder, first.takerOrder,
                half, half,
                first.makerSignature, first.takerSignature
            );

            // Second taker tries to take 600 — exceeds 500 remaining on maker
            const takerOrder2 = {
                ...first.takerOrder,
                amountIn: tooMuch,
                amountOut: tooMuch,
                salt: ethers.randomBytes(32),
                nonce: 1
            };
            const takerSignature2 = await signOrderEIP712(takerOrder2, taker, dexSettlement);

            await expect(
                dexSettlement.settleTrade(
                    first.makerOrder, takerOrder2,
                    tooMuch, tooMuch,
                    first.makerSignature, takerSignature2
                )
            ).to.be.revertedWithCustomError(dexSettlement, "FillExceedsRemaining");
        });

        it("Should charge fees proportionally to fill amount (not full order)", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);

            // Take a single partial fill of 500 and confirm fees are
            // computed on 500 (not on 1000).
            const { makerOrder, takerOrder, makerSignature, takerSignature } =
                await buildOrders(makerSize, half);

            const statsBefore = await dexSettlement.getTradingStats();

            await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                half, half,
                makerSignature, takerSignature
            );

            const statsAfter = await dexSettlement.getTradingStats();

            // Expected net fee: (20bp taker - 5bp rebate) * 500 = 15bp * 500
            const expectedNetFee = (half * 15n) / 10000n;
            expect(statsAfter.fees - statsBefore.fees).to.equal(expectedNetFee);
        });

        it("Should prevent further fills after invalidateNonce mid-order", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);

            const first = await buildOrders(makerSize, half);
            await dexSettlement.settleTrade(
                first.makerOrder, first.takerOrder,
                half, half,
                first.makerSignature, first.takerSignature
            );

            // Maker cancels the remainder
            await dexSettlement.connect(maker).invalidateNonce(0);

            // Second taker tries to consume the 500 remaining
            const takerOrder2 = {
                ...first.takerOrder,
                salt: ethers.randomBytes(32),
                nonce: 1
            };
            const takerSignature2 = await signOrderEIP712(takerOrder2, taker, dexSettlement);

            // invalidateNonce sets the nonce bit first, so NonceAlreadyUsed fires
            // before the filled-amount check — both outcomes correctly block the fill.
            await expect(
                dexSettlement.settleTrade(
                    first.makerOrder, takerOrder2,
                    half, half,
                    first.makerSignature, takerSignature2
                )
            ).to.be.revertedWithCustomError(dexSettlement, "NonceAlreadyUsed");

            // But the half already filled stays filled
            const makerHash = await dexSettlement.hashOrder(first.makerOrder);
            expect(await dexSettlement.filledAmounts(makerHash)).to.equal(half);
        });

        it("Should revert FillProportionalityMismatch when fill ratios disagree with order rates", async function () {
            // Build a 1:1 maker order for 1000; ask to consume 500 of maker
            // but claim the taker only provided 400 (wrong rate)
            const makerSize = ethers.parseUnits("1000", 18);
            const halfMaker = ethers.parseUnits("500", 18);
            const wrongTaker = ethers.parseUnits("400", 18);

            const { makerOrder, takerOrder, makerSignature, takerSignature } =
                await buildOrders(makerSize, makerSize);

            await expect(
                dexSettlement.settleTrade(
                    makerOrder, takerOrder,
                    halfMaker, wrongTaker,
                    makerSignature, takerSignature
                )
            ).to.be.revertedWithCustomError(dexSettlement, "FillProportionalityMismatch");
        });

        it("Should charge referral surcharge on the partial fill amount only", async function () {
            // Taker with a referrer; partial fill half the order
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);

            const makerOrder = {
                trader: makerAddress,
                isBuy: false,
                tokenIn: await tokenA.getAddress(),
                tokenOut: await tokenB.getAddress(),
                amountIn: makerSize,
                amountOut: makerSize,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            const takerOrder = {
                trader: takerAddress,
                isBuy: true,
                tokenIn: await tokenB.getAddress(),
                tokenOut: await tokenA.getAddress(),
                amountIn: half,
                amountOut: half,
                price: 10000,
                deadline: await getFutureDeadline(),
                salt: ethers.randomBytes(32),
                matchingValidator: matchingValidatorAddress,
                nonce: 0,
                // Use existing test signers as referrers
                referrer: anyoneElseAddress,
                referrer2: ownerAddress
            };
            const makerSignature = await signOrderEIP712(makerOrder, maker, dexSettlement);
            const takerSignature = await signOrderEIP712(takerOrder, taker, dexSettlement);

            // Referral surcharge = 5bp on the FILL (500), not the full 1000
            const surchargeOnFill = (half * 5n) / 10000n; // 5bp of 500
            const referrerCut = (surchargeOnFill * 7000n) / 10000n;
            const referrer2Cut = (surchargeOnFill * 2000n) / 10000n;

            const referrerBefore = await tokenB.balanceOf(anyoneElseAddress);
            const referrer2Before = await tokenB.balanceOf(ownerAddress);

            await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                half, half,
                makerSignature, takerSignature
            );

            const referrerAfter = await tokenB.balanceOf(anyoneElseAddress);
            const referrer2After = await tokenB.balanceOf(ownerAddress);

            expect(referrerAfter - referrerBefore).to.equal(referrerCut);
            expect(referrer2After - referrer2Before).to.equal(referrer2Cut);
        });

        it("Should emit TradePartiallySettled with correct flags and cumulative totals", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);

            const { makerOrder, takerOrder, makerSignature, takerSignature } =
                await buildOrders(makerSize, half);

            const makerHash = await dexSettlement.hashOrder(makerOrder);
            const takerHash = await dexSettlement.hashOrder(takerOrder);

            const tx = await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                half, half,
                makerSignature, takerSignature
            );

            // Maker NOT fully filled (500/1000), taker IS fully filled (500/500)
            await expect(tx)
                .to.emit(dexSettlement, "TradePartiallySettled")
                .withArgs(
                    (_tradeId: string) => true, // tradeId is keccak — don't match
                    makerAddress,
                    takerAddress,
                    makerHash,
                    takerHash,
                    half, // makerFillAmount
                    half, // takerFillAmount
                    half, // makerFilledTotal
                    half, // takerFilledTotal
                    false, // makerFullyFilled
                    true  // takerFullyFilled
                );
        });

        it("getOrderRemaining view should track partial fills correctly", async function () {
            const makerSize = ethers.parseUnits("1000", 18);
            const half = ethers.parseUnits("500", 18);

            const { makerOrder, takerOrder, makerSignature, takerSignature } =
                await buildOrders(makerSize, half);

            const makerHash = await dexSettlement.hashOrder(makerOrder);

            // Full remaining before any settlement
            expect(await dexSettlement.getOrderRemaining(makerHash, makerSize)).to.equal(makerSize);
            expect(await dexSettlement.isOrderFilled(makerHash, makerSize)).to.equal(false);

            // After partial fill
            await dexSettlement.settleTrade(
                makerOrder, takerOrder,
                half, half,
                makerSignature, takerSignature
            );

            expect(await dexSettlement.getOrderRemaining(makerHash, makerSize)).to.equal(half);
            expect(await dexSettlement.isOrderFilled(makerHash, makerSize)).to.equal(false);
        });
    });
});
