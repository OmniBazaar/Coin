/**
 * CLOBAdapter Tests
 *
 * Tests:
 * - Inventory management (deposit, clear expired)
 * - getAmountOut (quote)
 * - Access control (onlyRouter, onlyOwner)
 * - Rescue tokens
 * - Constructor validation
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe("CLOBAdapter", function () {
    let adapter: any;
    let owner: any, router: any, trader1: any, nonOwner: any;
    let tokenA: any, tokenB: any;
    let tokenAAddr: string, tokenBAddr: string;
    const INITIAL_BALANCE = ethers.parseUnits("10000000", 18);

    beforeEach(async function () {
        [owner, router, trader1, nonOwner] = await ethers.getSigners();

        const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
        tokenA = await ERC20Mock.deploy("Token A", "TKA");
        tokenB = await ERC20Mock.deploy("Token B", "TKB");
        tokenAAddr = await tokenA.getAddress();
        tokenBAddr = await tokenB.getAddress();

        await tokenA.mint(await owner.getAddress(), INITIAL_BALANCE);
        await tokenB.mint(await owner.getAddress(), INITIAL_BALANCE);

        // Deploy CLOBAdapter with a mock router (just a signer address)
        // and a mock DEXSettlement (another signer address)
        const CLOBAdapter = await ethers.getContractFactory("CLOBAdapter");
        adapter = await CLOBAdapter.deploy(
            await router.getAddress(),
            await trader1.getAddress(), // Mock DEXSettlement
            await owner.getAddress()
        );
        await adapter.waitForDeployment();
    });

    describe("Constructor", function () {
        it("Should set immutable addresses", async function () {
            expect(await adapter.router()).to.equal(await router.getAddress());
            expect(await adapter.dexSettlement()).to.equal(await trader1.getAddress());
        });

        it("Should revert with zero router", async function () {
            const CLOBAdapter = await ethers.getContractFactory("CLOBAdapter");
            await expect(
                CLOBAdapter.deploy(ethers.ZeroAddress, await trader1.getAddress(), await owner.getAddress())
            ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
        });

        it("Should revert with zero dexSettlement", async function () {
            const CLOBAdapter = await ethers.getContractFactory("CLOBAdapter");
            await expect(
                CLOBAdapter.deploy(await router.getAddress(), ethers.ZeroAddress, await owner.getAddress())
            ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
        });
    });

    describe("Inventory Management", function () {
        it("Should deposit a maker order", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline: (await ethers.provider.getBlock("latest"))!.timestamp + 86400,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            await expect(
                adapter.depositMakerOrder(order, "0x1234")
            ).to.emit(adapter, "OrderDeposited")
                .withArgs(pairHash, await trader1.getAddress(), order.amountIn);

            expect(await adapter.inventoryCount(pairHash)).to.equal(1);
        });

        it("Should reject deposit from non-owner", async function () {
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline: (await ethers.provider.getBlock("latest"))!.timestamp + 86400,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            await expect(
                adapter.connect(nonOwner).depositMakerOrder(order, "0x1234")
            ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
        });

        it("Should clear expired orders", async function () {
            // M-02 validation rejects deposits with a past deadline, so
            // deposit a live order and advance time past its deadline.
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline: (await ethers.provider.getBlock("latest"))!.timestamp + 60,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };

            await adapter.depositMakerOrder(order, "0x1234");
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );
            expect(await adapter.inventoryCount(pairHash)).to.equal(1);

            await ethers.provider.send("evm_increaseTime", [120]);
            await ethers.provider.send("evm_mine", []);

            await expect(
                adapter.clearExpiredOrders(tokenAAddr, tokenBAddr)
            ).to.emit(adapter, "ExpiredOrdersCleared")
                .withArgs(pairHash, 1);

            expect(await adapter.inventoryCount(pairHash)).to.equal(0);
        });

        it("Should let the owner remove a specific deposited order (RT-EC-02)", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );
            const deadline = (await ethers.provider.getBlock("latest"))!.timestamp + 86400;
            const makeOrder = async (salt: string) => ({
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline,
                salt,
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            });

            await adapter.depositMakerOrder(
                await makeOrder(ethers.hexlify(ethers.randomBytes(32))),
                "0x1234"
            );
            await adapter.depositMakerOrder(
                await makeOrder(ethers.hexlify(ethers.randomBytes(32))),
                "0x5678"
            );
            expect(await adapter.inventoryCount(pairHash)).to.equal(2);

            await expect(
                adapter.removeMakerOrder(tokenAAddr, tokenBAddr, 0)
            ).to.emit(adapter, "OrderRemoved")
                .withArgs(pairHash, 0);

            expect(await adapter.inventoryCount(pairHash)).to.equal(1);
        });

        it("Should revert removeMakerOrder with an out-of-bounds index", async function () {
            const deadline = (await ethers.provider.getBlock("latest"))!.timestamp + 86400;
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            await adapter.depositMakerOrder(order, "0x1234");

            await expect(
                adapter.removeMakerOrder(tokenAAddr, tokenBAddr, 5)
            ).to.be.revertedWithCustomError(adapter, "InvalidOrder");
        });

        it("Should revert removeMakerOrder from a non-owner", async function () {
            const deadline = (await ethers.provider.getBlock("latest"))!.timestamp + 86400;
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            await adapter.depositMakerOrder(order, "0x1234");

            await expect(
                adapter.connect(nonOwner).removeMakerOrder(tokenAAddr, tokenBAddr, 0)
            ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
        });
    });

    describe("Quote (getAmountOut)", function () {
        it("Should return 0 when no inventory", async function () {
            const amountOut = await adapter.getAmountOut(
                tokenBAddr, tokenAAddr, ethers.parseUnits("100", 18)
            );
            expect(amountOut).to.equal(0);
        });

        it("Should return correct quote from inventory", async function () {
            // Maker selling 100 TKA for 200 TKB (price: 2 TKB per TKA)
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("200", 18),
                price: 20000,
                deadline: (await ethers.provider.getBlock("latest"))!.timestamp + 86400,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            await adapter.depositMakerOrder(order, "0x1234");

            // Taker wants to buy TKA with TKB. TokenIn=TKB, TokenOut=TKA
            // Pair hash for getAmountOut: keccak256(tokenOut, tokenIn) = keccak256(TKA, TKB) = maker's pair
            const amountOut = await adapter.getAmountOut(
                tokenBAddr, tokenAAddr, ethers.parseUnits("200", 18)
            );
            // Maker offers 100 TKA for 200 TKB, taker has 200 TKB → gets 100 TKA
            expect(amountOut).to.equal(ethers.parseUnits("100", 18));
        });

        it("RT-01 regression: selects the BEST (highest received-per-paid) order, not the worst", async function () {
            // Two maker orders in the same pair (maker sells TKA for TKB):
            //   GOOD: gives 100 TKA per 50 TKB  → taker receives 2.0 TKA per TKB
            //   BAD:  gives 100 TKA per 150 TKB → taker receives 0.667 TKA per TKB
            // priceRatio = amountIn/amountOut is received-per-paid, so the
            // adapter must MAXIMIZE it. The pre-fix code minimized it and
            // executed every multi-order pair at the worst price.
            const deadline = (await ethers.provider.getBlock("latest"))!.timestamp + 86400;
            const goodOrder = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            const badOrder = { ...goodOrder, amountOut: ethers.parseUnits("150", 18), salt: ethers.hexlify(ethers.randomBytes(32)) };
            await adapter.depositMakerOrder(goodOrder, "0x1234");
            await adapter.depositMakerOrder(badOrder, "0x5678");

            // Taker swaps 10 TKB → TKA. Best order yields 10 * 100/50 = 20 TKA.
            const amountOut = await adapter.getAmountOut(
                tokenBAddr, tokenAAddr, ethers.parseUnits("10", 18)
            );
            expect(amountOut).to.equal(ethers.parseUnits("20", 18));

            // Explicit guard: never quote below the worst-order rate.
            const worstCase = (ethers.parseUnits("10", 18) * ethers.parseUnits("100", 18)) / ethers.parseUnits("150", 18);
            expect(amountOut).to.be.gte(worstCase);
        });
    });

    describe("executeSwap Access Control", function () {
        it("Should revert when called by non-router", async function () {
            await expect(
                adapter.connect(nonOwner).executeSwap(
                    tokenAAddr, tokenBAddr,
                    ethers.parseUnits("100", 18),
                    0, // minAmountOut (H-01 slippage param)
                    await nonOwner.getAddress()
                )
            ).to.be.revertedWithCustomError(adapter, "OnlyRouter");
        });
    });

    describe("Rescue Tokens", function () {
        it("Should rescue stuck tokens", async function () {
            // Send tokens to the adapter
            await tokenA.transfer(await adapter.getAddress(), ethers.parseUnits("100", 18));

            await expect(
                adapter.rescueTokens(
                    tokenAAddr,
                    await owner.getAddress(),
                    ethers.parseUnits("100", 18)
                )
            ).to.emit(adapter, "TokensRescued")
                .withArgs(tokenAAddr, await owner.getAddress(), ethers.parseUnits("100", 18));
        });

        it("Should revert rescue from non-owner", async function () {
            await expect(
                adapter.connect(nonOwner).rescueTokens(
                    tokenAAddr,
                    await nonOwner.getAddress(),
                    ethers.parseUnits("100", 18)
                )
            ).to.be.revertedWithCustomError(adapter, "OwnableUnauthorizedAccount");
        });
    });

    describe("Partial Fill (D-01 regression)", function () {
        let realAdapter: any;
        let mockSettlement: any;

        beforeEach(async function () {
            // Deploy a real (token-moving) mock DEXSettlement and point the
            // adapter at it so executeSwap can run end-to-end.
            const Mock = await ethers.getContractFactory("MockDEXSettlementForCLOB");
            mockSettlement = await Mock.deploy();
            await mockSettlement.waitForDeployment();

            const CLOBAdapter = await ethers.getContractFactory("CLOBAdapter");
            realAdapter = await CLOBAdapter.deploy(
                await router.getAddress(),
                await mockSettlement.getAddress(),
                await owner.getAddress()
            );
            await realAdapter.waitForDeployment();

            // Maker sells 100 TKA for 50 TKB.
            const order = {
                trader: await trader1.getAddress(),
                isBuy: false,
                tokenIn: tokenAAddr,
                tokenOut: tokenBAddr,
                amountIn: ethers.parseUnits("100", 18),
                amountOut: ethers.parseUnits("50", 18),
                price: 5000,
                deadline: (await ethers.provider.getBlock("latest"))!.timestamp + 86400,
                salt: ethers.hexlify(ethers.randomBytes(32)),
                matchingValidator: ethers.ZeroAddress,
                nonce: 0,
                referrer: ethers.ZeroAddress,
                referrer2: ethers.ZeroAddress
            };
            await realAdapter.depositMakerOrder(order, "0x1234");

            // Fund the mock with TKA (the maker's sold token) so it can pay
            // the adapter, and fund+approve the router so the adapter can
            // pull TKB (the taker's paid token) from it.
            await tokenA.mint(await mockSettlement.getAddress(), INITIAL_BALANCE);
            await tokenB.mint(await router.getAddress(), INITIAL_BALANCE);
            await tokenB.connect(router).approve(
                await realAdapter.getAddress(), ethers.MaxUint256
            );
        });

        it("Should NOT mutate the signed order on partial fill, and should refill correctly", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );

            // Taker swaps 10 TKB → expects 20 TKA (10 * 100/50).
            await realAdapter.connect(router).executeSwap(
                tokenBAddr, tokenAAddr,
                ethers.parseUnits("10", 18),
                0,
                await router.getAddress()
            );

            // The signed order must be untouched — only remainingIn/Out move.
            // If order.amountIn/amountOut had been reduced, the maker's EIP-712
            // signature would no longer hash-match on the next fill (D-01).
            const item = await realAdapter.inventory(pairHash, 0);
            expect(item.order.amountIn).to.equal(ethers.parseUnits("100", 18));
            expect(item.order.amountOut).to.equal(ethers.parseUnits("50", 18));
            expect(item.remainingIn).to.equal(ethers.parseUnits("80", 18));
            expect(item.remainingOut).to.equal(ethers.parseUnits("40", 18));

            // The key regression: the second partial fill must SUCCEED (before
            // the fix it reverted because the mutated amounts invalidated the
            // signature).
            await expect(
                realAdapter.connect(router).executeSwap(
                    tokenBAddr, tokenAAddr,
                    ethers.parseUnits("10", 18),
                    0,
                    await router.getAddress()
                )
            ).to.not.be.reverted;

            const item2 = await realAdapter.inventory(pairHash, 0);
            expect(item2.remainingIn).to.equal(ethers.parseUnits("60", 18));
            expect(item2.remainingOut).to.equal(ethers.parseUnits("30", 18));
        });

        it("Should remove the order once its remaining output is fully consumed", async function () {
            const pairHash = ethers.keccak256(
                ethers.solidityPacked(["address", "address"], [tokenAAddr, tokenBAddr])
            );

            // Consume the full 50 TKB in one swap.
            await realAdapter.connect(router).executeSwap(
                tokenBAddr, tokenAAddr,
                ethers.parseUnits("50", 18),
                0,
                await router.getAddress()
            );

            expect(await realAdapter.inventoryCount(pairHash)).to.equal(0);
        });
    });
});
