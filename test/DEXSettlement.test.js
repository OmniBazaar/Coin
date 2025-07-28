const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DEXSettlement", function () {
    let owner, matcher, trader1, trader2, trader3, treasury, feeCollector;
    let registry, omniCoin, privateOmniCoin, mockUSDC, mockPriceOracle;
    let dexSettlement;
    
    // Constants
    const FEE_BASIS_POINTS = 30; // 0.3%
    const MIN_ORDER_SIZE = ethers.parseUnits("10", 6);
    const MAX_ORDER_SIZE = ethers.parseUnits("1000000", 6);
    
    // Order types
    const OrderType = {
        Market: 0,
        Limit: 1,
        StopLoss: 2,
        TakeProfit: 3
    };
    
    // Order sides
    const OrderSide = {
        Buy: 0,
        Sell: 1
    };
    
    beforeEach(async function () {
        [owner, matcher, trader1, trader2, trader3, treasury, feeCollector] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test
        const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        privateOmniCoin = await StandardERC20Test.deploy();
        await privateOmniCoin.waitForDeployment();
        
        // For USDC, use StandardERC20Test (representing third-party token)
        const StandardERC20Test2 = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        mockUSDC = await StandardERC20Test2.deploy();
        await mockUSDC.waitForDeployment();
        
        // Deploy actual PriceOracle
        const PriceOracle = await ethers.getContractFactory("PriceOracle");
        mockPriceOracle = await PriceOracle.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await mockPriceOracle.waitForDeployment();
        
        // Set initial prices
        await mockPriceOracle.setPrice(await omniCoin.getAddress(), ethers.parseUnits("10", 8)); // $10
        await mockPriceOracle.setPrice(await mockUSDC.getAddress(), ethers.parseUnits("1", 8)); // $1
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("FEE_RECIPIENT")),
            await feeCollector.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRICE_ORACLE")),
            await mockPriceOracle.getAddress()
        );
        
        // Deploy DEXSettlement
        const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
        dexSettlement = await DEXSettlement.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await dexSettlement.waitForDeployment();
        
        // Setup
        await dexSettlement.connect(owner).addMatcher(await matcher.getAddress());
        await dexSettlement.connect(owner).addSupportedToken(await omniCoin.getAddress());
        await dexSettlement.connect(owner).addSupportedToken(await mockUSDC.getAddress());
        
        // Fund traders
        const fundAmount = ethers.parseUnits("10000", 6);
        await omniCoin.mint(await trader1.getAddress(), fundAmount);
        await omniCoin.mint(await trader2.getAddress(), fundAmount);
        await mockUSDC.mint(await trader1.getAddress(), fundAmount);
        await mockUSDC.mint(await trader2.getAddress(), fundAmount);
        await mockUSDC.mint(await trader3.getAddress(), fundAmount);
        
        // Approve DEX
        await omniCoin.connect(trader1).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(trader2).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
        await mockUSDC.connect(trader1).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
        await mockUSDC.connect(trader2).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
        await mockUSDC.connect(trader3).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await dexSettlement.owner()).to.equal(await owner.getAddress());
            expect(await dexSettlement.feeBasisPoints()).to.equal(FEE_BASIS_POINTS);
            expect(await dexSettlement.minOrderSize()).to.equal(MIN_ORDER_SIZE);
            expect(await dexSettlement.maxOrderSize()).to.equal(MAX_ORDER_SIZE);
        });
        
        it("Should update fee basis points", async function () {
            const newFee = 50; // 0.5%
            
            await expect(dexSettlement.connect(owner).setFeeBasisPoints(newFee))
                .to.emit(dexSettlement, "FeeUpdated")
                .withArgs(FEE_BASIS_POINTS, newFee);
            
            expect(await dexSettlement.feeBasisPoints()).to.equal(newFee);
        });
        
        it("Should update order size limits", async function () {
            const newMin = ethers.parseUnits("5", 6);
            const newMax = ethers.parseUnits("2000000", 6);
            
            await dexSettlement.connect(owner).setOrderSizeLimits(newMin, newMax);
            
            expect(await dexSettlement.minOrderSize()).to.equal(newMin);
            expect(await dexSettlement.maxOrderSize()).to.equal(newMax);
        });
    });
    
    describe("Token Management", function () {
        it("Should add supported token", async function () {
            const newToken = await trader3.getAddress(); // Mock address
            
            await expect(dexSettlement.connect(owner).addSupportedToken(newToken))
                .to.emit(dexSettlement, "TokenAdded")
                .withArgs(newToken);
            
            expect(await dexSettlement.supportedTokens(newToken)).to.be.true;
        });
        
        it("Should remove supported token", async function () {
            await expect(
                dexSettlement.connect(owner).removeSupportedToken(await mockUSDC.getAddress())
            ).to.emit(dexSettlement, "TokenRemoved")
                .withArgs(await mockUSDC.getAddress());
            
            expect(await dexSettlement.supportedTokens(await mockUSDC.getAddress())).to.be.false;
        });
        
        it("Should create trading pair", async function () {
            await expect(
                dexSettlement.connect(owner).createTradingPair(
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress()
                )
            ).to.emit(dexSettlement, "TradingPairCreated")
                .withArgs(await omniCoin.getAddress(), await mockUSDC.getAddress());
            
            const pairId = await dexSettlement.getPairId(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
            
            expect(await dexSettlement.isTradingPairActive(pairId)).to.be.true;
        });
    });
    
    describe("Order Creation", function () {
        beforeEach(async function () {
            // Create OMC/USDC trading pair
            await dexSettlement.connect(owner).createTradingPair(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
        });
        
        it("Should create limit buy order", async function () {
            const amount = ethers.parseUnits("100", 6); // 100 OMC
            const price = ethers.parseUnits("9", 6); // $9 per OMC
            
            await expect(
                dexSettlement.connect(trader1).createOrder(
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress(),
                    OrderType.Limit,
                    OrderSide.Buy,
                    amount,
                    price
                )
            ).to.emit(dexSettlement, "OrderCreated")
                .withArgs(
                    1, // order ID
                    await trader1.getAddress(),
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress(),
                    OrderType.Limit,
                    OrderSide.Buy,
                    amount,
                    price
                );
            
            const order = await dexSettlement.orders(1);
            expect(order.trader).to.equal(await trader1.getAddress());
            expect(order.baseToken).to.equal(await omniCoin.getAddress());
            expect(order.quoteToken).to.equal(await mockUSDC.getAddress());
            expect(order.amount).to.equal(amount);
            expect(order.price).to.equal(price);
            expect(order.isActive).to.be.true;
        });
        
        it("Should create limit sell order", async function () {
            const amount = ethers.parseUnits("50", 6); // 50 OMC
            const price = ethers.parseUnits("11", 6); // $11 per OMC
            
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                amount,
                price
            );
            
            const order = await dexSettlement.orders(1);
            expect(order.orderSide).to.equal(OrderSide.Sell);
            expect(order.amount).to.equal(amount);
        });
        
        it("Should create market order", async function () {
            const amount = ethers.parseUnits("30", 6);
            
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Market,
                OrderSide.Buy,
                amount,
                0 // Market orders don't specify price
            );
            
            const order = await dexSettlement.orders(1);
            expect(order.orderType).to.equal(OrderType.Market);
        });
        
        it("Should fail if order too small", async function () {
            await expect(
                dexSettlement.connect(trader1).createOrder(
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress(),
                    OrderType.Limit,
                    OrderSide.Buy,
                    MIN_ORDER_SIZE - 1n,
                    ethers.parseUnits("10", 6)
                )
            ).to.be.revertedWithCustomError(dexSettlement, "OrderTooSmall");
        });
        
        it("Should fail if order too large", async function () {
            await expect(
                dexSettlement.connect(trader1).createOrder(
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress(),
                    OrderType.Limit,
                    OrderSide.Buy,
                    MAX_ORDER_SIZE + 1n,
                    ethers.parseUnits("10", 6)
                )
            ).to.be.revertedWithCustomError(dexSettlement, "OrderTooLarge");
        });
    });
    
    describe("Order Matching", function () {
        beforeEach(async function () {
            await dexSettlement.connect(owner).createTradingPair(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
        });
        
        it("Should match buy and sell orders", async function () {
            // Create sell order: 100 OMC at $10
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            // Create buy order: 100 OMC at $10
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Buy,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            // Match orders
            await expect(dexSettlement.connect(matcher).matchOrders(1, 2))
                .to.emit(dexSettlement, "OrdersMatched")
                .withArgs(1, 2, ethers.parseUnits("100", 6), ethers.parseUnits("10", 6));
            
            // Check orders are filled
            expect((await dexSettlement.orders(1)).filled).to.equal(ethers.parseUnits("100", 6));
            expect((await dexSettlement.orders(2)).filled).to.equal(ethers.parseUnits("100", 6));
            expect((await dexSettlement.orders(1)).isActive).to.be.false;
            expect((await dexSettlement.orders(2)).isActive).to.be.false;
        });
        
        it("Should partially fill orders", async function () {
            // Create large sell order
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                ethers.parseUnits("200", 6),
                ethers.parseUnits("10", 6)
            );
            
            // Create smaller buy order
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Buy,
                ethers.parseUnits("50", 6),
                ethers.parseUnits("10", 6)
            );
            
            await dexSettlement.connect(matcher).matchOrders(1, 2);
            
            // Check partial fill
            expect((await dexSettlement.orders(1)).filled).to.equal(ethers.parseUnits("50", 6));
            expect((await dexSettlement.orders(2)).filled).to.equal(ethers.parseUnits("50", 6));
            expect((await dexSettlement.orders(1)).isActive).to.be.true; // Still active
            expect((await dexSettlement.orders(2)).isActive).to.be.false; // Fully filled
        });
        
        it("Should only allow matcher to match orders", async function () {
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Buy,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            await expect(
                dexSettlement.connect(trader1).matchOrders(1, 2)
            ).to.be.revertedWithCustomError(dexSettlement, "UnauthorizedMatcher");
        });
    });
    
    describe("Order Cancellation", function () {
        beforeEach(async function () {
            await dexSettlement.connect(owner).createTradingPair(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
            
            // Create an order
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Buy,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
        });
        
        it("Should cancel order by trader", async function () {
            await expect(dexSettlement.connect(trader1).cancelOrder(1))
                .to.emit(dexSettlement, "OrderCancelled")
                .withArgs(1, await trader1.getAddress());
            
            const order = await dexSettlement.orders(1);
            expect(order.isActive).to.be.false;
        });
        
        it("Should not cancel other trader's order", async function () {
            await expect(
                dexSettlement.connect(trader2).cancelOrder(1)
            ).to.be.revertedWithCustomError(dexSettlement, "UnauthorizedCancellation");
        });
        
        it("Should not cancel already filled order", async function () {
            // Create matching order
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            // Match orders
            await dexSettlement.connect(matcher).matchOrders(1, 2);
            
            await expect(
                dexSettlement.connect(trader1).cancelOrder(1)
            ).to.be.revertedWithCustomError(dexSettlement, "OrderNotActive");
        });
    });
    
    describe("Fee Collection", function () {
        beforeEach(async function () {
            await dexSettlement.connect(owner).createTradingPair(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
        });
        
        it("Should collect fees on trades", async function () {
            const tradeAmount = ethers.parseUnits("100", 6);
            const price = ethers.parseUnits("10", 6);
            const expectedFee = (tradeAmount * BigInt(FEE_BASIS_POINTS)) / 10000n;
            
            const feeCollectorBalanceBefore = await omniCoin.balanceOf(await feeCollector.getAddress());
            
            // Create and match orders
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                tradeAmount,
                price
            );
            
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Buy,
                tradeAmount,
                price
            );
            
            await dexSettlement.connect(matcher).matchOrders(1, 2);
            
            // Check fee collection
            expect(await omniCoin.balanceOf(await feeCollector.getAddress()))
                .to.equal(feeCollectorBalanceBefore + expectedFee);
        });
    });
    
    describe("Order Book Queries", function () {
        beforeEach(async function () {
            await dexSettlement.connect(owner).createTradingPair(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
            
            // Create multiple orders
            for (let i = 0; i < 5; i++) {
                await dexSettlement.connect(trader1).createOrder(
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress(),
                    OrderType.Limit,
                    OrderSide.Buy,
                    ethers.parseUnits("10", 6),
                    ethers.parseUnits(String(9 - i * 0.1), 6)
                );
            }
        });
        
        it("Should get orders by trader", async function () {
            const orders = await dexSettlement.getOrdersByTrader(await trader1.getAddress());
            expect(orders.length).to.equal(5);
        });
        
        it("Should get active orders for pair", async function () {
            const pairId = await dexSettlement.getPairId(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
            
            const orders = await dexSettlement.getActiveOrdersForPair(pairId);
            expect(orders.length).to.equal(5);
        });
    });
    
    describe("Emergency Functions", function () {
        it("Should pause trading", async function () {
            await dexSettlement.connect(owner).pause();
            
            await expect(
                dexSettlement.connect(trader1).createOrder(
                    await omniCoin.getAddress(),
                    await mockUSDC.getAddress(),
                    OrderType.Limit,
                    OrderSide.Buy,
                    ethers.parseUnits("100", 6),
                    ethers.parseUnits("10", 6)
                )
            ).to.be.revertedWithCustomError(dexSettlement, "EnforcedPause");
        });
        
        it("Should emergency cancel all orders", async function () {
            await dexSettlement.connect(owner).createTradingPair(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress()
            );
            
            // Create orders
            await dexSettlement.connect(trader1).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Buy,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            await dexSettlement.connect(trader2).createOrder(
                await omniCoin.getAddress(),
                await mockUSDC.getAddress(),
                OrderType.Limit,
                OrderSide.Sell,
                ethers.parseUnits("100", 6),
                ethers.parseUnits("10", 6)
            );
            
            await expect(dexSettlement.connect(owner).emergencyCancelAllOrders())
                .to.emit(dexSettlement, "EmergencyCancellation");
            
            expect((await dexSettlement.orders(1)).isActive).to.be.false;
            expect((await dexSettlement.orders(2)).isActive).to.be.false;
        });
    });
});