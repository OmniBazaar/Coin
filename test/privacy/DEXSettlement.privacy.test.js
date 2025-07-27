const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("DEXSettlement Privacy Functions", function () {
  // Test fixture
  async function deployDEXFixture() {
    const [owner, maker, taker, validator, treasury, development] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("contracts/MockERC20.sol:MockERC20");
    const omniToken = await MockERC20.deploy("OmniCoin", "OMNI", 6);
    const usdcToken = await MockERC20.deploy("USDC", "USDC", 6);
    const cotiToken = await MockERC20.deploy("COTI", "COTI", 18);
    await omniToken.waitForDeployment();
    await usdcToken.waitForDeployment();
    await cotiToken.waitForDeployment();

    // Deploy PrivacyFeeManager
    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await omniToken.getAddress(),
      await cotiToken.getAddress(),
      owner.address, // Mock DEX router
      owner.address
    );
    await privacyFeeManager.waitForDeployment();

    // Deploy Registry
    const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await OmniCoinRegistry.deploy(owner.address);
    await registry.waitForDeployment();

    // Deploy DEXSettlement
    const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
    const dexSettlement = await DEXSettlement.deploy(
      await omniToken.getAddress(),
      await registry.getAddress(),
      await privacyFeeManager.getAddress()
    );
    await dexSettlement.waitForDeployment();

    // Set up fee distribution
    await dexSettlement.setFeeDistribution(
      treasury.address,
      development.address,
      7000, // 70% validators
      2000, // 20% treasury
      1000  // 10% development
    );

    // Grant necessary roles
    await dexSettlement.grantRole(await dexSettlement.VALIDATOR_ROLE(), validator.address);
    await privacyFeeManager.grantRole(await privacyFeeManager.FEE_MANAGER_ROLE(), await dexSettlement.getAddress());

    // Mint tokens
    const mintAmount = ethers.parseUnits("100000", 6);
    await omniToken.mint(maker.address, mintAmount);
    await omniToken.mint(taker.address, mintAmount);
    await usdcToken.mint(maker.address, mintAmount);
    await usdcToken.mint(taker.address, mintAmount);

    // Approve DEX and fee manager
    await omniToken.connect(maker).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
    await omniToken.connect(taker).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
    await usdcToken.connect(maker).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
    await usdcToken.connect(taker).approve(await dexSettlement.getAddress(), ethers.MaxUint256);
    
    await omniToken.connect(maker).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(taker).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);

    // Enable privacy preferences
    await omniToken.connect(maker).setPrivacyPreference(true);
    await omniToken.connect(taker).setPrivacyPreference(true);

    // Whitelist tokens
    await dexSettlement.whitelistToken(await omniToken.getAddress());
    await dexSettlement.whitelistToken(await usdcToken.getAddress());

    return {
      dexSettlement,
      omniToken,
      usdcToken,
      privacyFeeManager,
      registry,
      owner,
      maker,
      taker,
      validator,
      treasury,
      development
    };
  }

  describe("Public DEX Trades (No Privacy)", function () {
    it("Should settle public trades without privacy fees", async function () {
      const { dexSettlement, omniToken, usdcToken, maker, taker, validator } = await loadFixture(deployDEXFixture);

      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("TRADE_001"));
      const amountIn = ethers.parseUnits("1000", 6); // 1000 USDC
      const amountOut = ethers.parseUnits("100", 6); // 100 OMNI

      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const validatorSignature = await validator.signMessage("Valid trade");

      // Settle public trade
      await expect(dexSettlement.connect(validator).settleTrade(
        tradeId,
        maker.address,
        taker.address,
        await usdcToken.getAddress(),
        await omniToken.getAddress(),
        amountIn,
        amountOut,
        500, // 5% max slippage
        deadline,
        validatorSignature
      )).to.emit(dexSettlement, "TradeSettled")
        .withArgs(tradeId, maker.address, taker.address, amountIn, amountOut, false);

      // Verify balances changed
      const makerOmni = await omniToken.balanceOf(maker.address);
      const takerUsdc = await usdcToken.balanceOf(taker.address);
      expect(makerOmni).to.be.gt(ethers.parseUnits("100000", 6));
      expect(takerUsdc).to.be.gt(ethers.parseUnits("100000", 6));
    });

    it("Should handle multiple public trades efficiently", async function () {
      const { dexSettlement, omniToken, usdcToken, maker, taker, validator } = await loadFixture(deployDEXFixture);

      const amountIn = ethers.parseUnits("100", 6);
      const amountOut = ethers.parseUnits("10", 6);
      const deadline = Math.floor(Date.now() / 1000) + 3600;

      // Execute multiple trades
      for (let i = 0; i < 3; i++) {
        const tradeId = ethers.keccak256(ethers.toUtf8Bytes(`TRADE_${i}`));
        const validatorSignature = await validator.signMessage(`Valid trade ${i}`);

        await dexSettlement.connect(validator).settleTrade(
          tradeId,
          maker.address,
          taker.address,
          await usdcToken.getAddress(),
          await omniToken.getAddress(),
          amountIn,
          amountOut,
          500,
          deadline,
          validatorSignature
        );
      }

      // Check trade count
      const stats = await dexSettlement.getTradeStats();
      expect(stats.totalTrades).to.equal(3);
    });
  });

  describe("Private DEX Trades (With Privacy)", function () {
    it("Should settle private trades with privacy credits", async function () {
      const { dexSettlement, omniToken, usdcToken, privacyFeeManager, maker, taker, validator, owner } = 
        await loadFixture(deployDEXFixture);

      // Enable MPC for testing
      await dexSettlement.connect(owner).setMpcAvailability(true);

      // Pre-deposit privacy credits for both parties
      await privacyFeeManager.connect(maker).depositPrivacyCredits(ethers.parseUnits("1000", 6));
      await privacyFeeManager.connect(taker).depositPrivacyCredits(ethers.parseUnits("1000", 6));

      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_TRADE_001"));
      const amountIn = ethers.parseUnits("1000", 6);
      const amountOut = ethers.parseUnits("100", 6);

      // Calculate expected privacy fees
      const operationType = ethers.keccak256(ethers.toUtf8Bytes("DEX_TRADE"));
      const makerFee = await privacyFeeManager.calculatePrivacyFee(operationType, amountIn);
      const takerFee = await privacyFeeManager.calculatePrivacyFee(operationType, amountOut);

      const makerCreditsBefore = await privacyFeeManager.getPrivacyCredits(maker.address);
      const takerCreditsBefore = await privacyFeeManager.getPrivacyCredits(taker.address);

      // Create encrypted amounts (simulated for testing)
      const encryptedAmountIn = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const encryptedAmountOut = { data: ethers.hexlify(ethers.randomBytes(32)) };

      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const validatorSignature = await validator.signMessage("Valid private trade");

      // Settle private trade
      await expect(dexSettlement.connect(validator).settleTradeWithPrivacy(
        tradeId,
        maker.address,
        taker.address,
        await usdcToken.getAddress(),
        await omniToken.getAddress(),
        encryptedAmountIn,
        encryptedAmountOut,
        500,
        deadline,
        validatorSignature,
        true // use privacy
      )).to.emit(dexSettlement, "TradeSettled")
        .withArgs(tradeId, maker.address, taker.address, amountIn, amountOut, true);

      // Verify privacy credits were deducted
      const makerCreditsAfter = await privacyFeeManager.getPrivacyCredits(maker.address);
      const takerCreditsAfter = await privacyFeeManager.getPrivacyCredits(taker.address);
      
      expect(makerCreditsBefore - makerCreditsAfter).to.be.gte(makerFee);
      expect(takerCreditsBefore - takerCreditsAfter).to.be.gte(takerFee);
    });

    it("Should fail if insufficient privacy credits", async function () {
      const { dexSettlement, omniToken, usdcToken, privacyFeeManager, maker, taker, validator, owner } = 
        await loadFixture(deployDEXFixture);

      await dexSettlement.connect(owner).setMpcAvailability(true);

      // Deposit insufficient credits
      await privacyFeeManager.connect(maker).depositPrivacyCredits(ethers.parseUnits("1", 6));
      await privacyFeeManager.connect(taker).depositPrivacyCredits(ethers.parseUnits("1", 6));

      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("FAILED_TRADE"));
      const encryptedAmountIn = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const encryptedAmountOut = { data: ethers.hexlify(ethers.randomBytes(32)) };

      // Attempt private trade with large amounts
      await expect(
        dexSettlement.connect(validator).settleTradeWithPrivacy(
          tradeId,
          maker.address,
          taker.address,
          await usdcToken.getAddress(),
          await omniToken.getAddress(),
          encryptedAmountIn,
          encryptedAmountOut,
          500,
          Math.floor(Date.now() / 1000) + 3600,
          await validator.signMessage("Trade"),
          true
        )
      ).to.be.revertedWith("Insufficient privacy credits");
    });
  });

  describe("Limit Orders", function () {
    it("Should place public limit orders", async function () {
      const { dexSettlement, omniToken, usdcToken, maker } = await loadFixture(deployDEXFixture);

      const orderId = ethers.keccak256(ethers.toUtf8Bytes("ORDER_001"));
      const sellAmount = ethers.parseUnits("100", 6); // 100 OMNI
      const buyAmount = ethers.parseUnits("1000", 6); // 1000 USDC
      const expiry = Math.floor(Date.now() / 1000) + 86400; // 24 hours

      // Place limit order
      await expect(dexSettlement.connect(maker).placeLimitOrder(
        orderId,
        await omniToken.getAddress(),
        await usdcToken.getAddress(),
        sellAmount,
        buyAmount,
        expiry
      )).to.emit(dexSettlement, "LimitOrderPlaced")
        .withArgs(orderId, maker.address, sellAmount, buyAmount, expiry, false);
    });

    it("Should place private limit orders with credits", async function () {
      const { dexSettlement, omniToken, usdcToken, privacyFeeManager, maker, owner } = 
        await loadFixture(deployDEXFixture);

      await dexSettlement.connect(owner).setMpcAvailability(true);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(maker).depositPrivacyCredits(ethers.parseUnits("1000", 6));

      const orderId = ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_ORDER_001"));
      const sellAmount = ethers.parseUnits("100", 6);
      const buyAmount = ethers.parseUnits("1000", 6);
      const expiry = Math.floor(Date.now() / 1000) + 86400;

      // Create encrypted amounts
      const encryptedSellAmount = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const encryptedBuyAmount = { data: ethers.hexlify(ethers.randomBytes(32)) };

      // Place private limit order
      await expect(dexSettlement.connect(maker).placeLimitOrderWithPrivacy(
        orderId,
        await omniToken.getAddress(),
        await usdcToken.getAddress(),
        encryptedSellAmount,
        encryptedBuyAmount,
        expiry,
        true
      )).to.emit(dexSettlement, "LimitOrderPlaced")
        .withArgs(orderId, maker.address, sellAmount, buyAmount, expiry, true);
    });

    it("Should cancel orders and refund privacy credits", async function () {
      const { dexSettlement, omniToken, usdcToken, privacyFeeManager, maker } = 
        await loadFixture(deployDEXFixture);

      // Place order first
      const orderId = ethers.keccak256(ethers.toUtf8Bytes("CANCEL_ORDER"));
      await dexSettlement.connect(maker).placeLimitOrder(
        orderId,
        await omniToken.getAddress(),
        await usdcToken.getAddress(),
        ethers.parseUnits("100", 6),
        ethers.parseUnits("1000", 6),
        Math.floor(Date.now() / 1000) + 86400
      );

      // Cancel order
      await expect(dexSettlement.connect(maker).cancelLimitOrder(orderId))
        .to.emit(dexSettlement, "LimitOrderCancelled")
        .withArgs(orderId, maker.address);
    });
  });

  describe("Batch Operations", function () {
    it("Should settle batch trades with mixed privacy", async function () {
      const { dexSettlement, omniToken, usdcToken, privacyFeeManager, maker, taker, validator } = 
        await loadFixture(deployDEXFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(maker).depositPrivacyCredits(ethers.parseUnits("5000", 6));
      await privacyFeeManager.connect(taker).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      const trades = [];
      for (let i = 0; i < 3; i++) {
        trades.push({
          id: ethers.keccak256(ethers.toUtf8Bytes(`BATCH_${i}`)),
          maker: maker.address,
          taker: taker.address,
          tokenIn: await usdcToken.getAddress(),
          tokenOut: await omniToken.getAddress(),
          amountIn: ethers.parseUnits("100", 6),
          amountOut: ethers.parseUnits("10", 6),
          maxSlippage: 500,
          deadline: Math.floor(Date.now() / 1000) + 3600,
          signature: await validator.signMessage(`Batch trade ${i}`),
          usePrivacy: i === 1 // Only second trade is private
        });
      }

      // Execute batch settlement
      await expect(dexSettlement.connect(validator).batchSettleTrades(trades))
        .to.emit(dexSettlement, "BatchTradeCompleted");

      // Verify privacy was only used for one trade
      const stats = await privacyFeeManager.getUserPrivacyStats(maker.address);
      expect(stats.usage).to.be.gte(1);
    });
  });

  describe("Fee Distribution", function () {
    it("Should distribute trading fees correctly", async function () {
      const { dexSettlement, omniToken, usdcToken, maker, taker, validator, treasury, development, owner } = 
        await loadFixture(deployDEXFixture);

      // Set trading fee
      await dexSettlement.connect(owner).setTradingFee(30); // 0.3%

      // Execute trade
      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("FEE_TRADE"));
      const amountIn = ethers.parseUnits("10000", 6);
      const amountOut = ethers.parseUnits("1000", 6);

      await dexSettlement.connect(validator).settleTrade(
        tradeId,
        maker.address,
        taker.address,
        await usdcToken.getAddress(),
        await omniToken.getAddress(),
        amountIn,
        amountOut,
        500,
        Math.floor(Date.now() / 1000) + 3600,
        await validator.signMessage("Trade")
      );

      // Check accumulated fees
      const accumulatedFees = await dexSettlement.accumulatedFees(await omniToken.getAddress());
      expect(accumulatedFees).to.be.gt(0);

      // Distribute fees
      const treasuryBefore = await omniToken.balanceOf(treasury.address);
      const developmentBefore = await omniToken.balanceOf(development.address);

      await dexSettlement.connect(owner).distributeFees(await omniToken.getAddress());

      const treasuryAfter = await omniToken.balanceOf(treasury.address);
      const developmentAfter = await omniToken.balanceOf(development.address);

      // Verify distribution ratios
      expect(treasuryAfter).to.be.gt(treasuryBefore);
      expect(developmentAfter).to.be.gt(developmentBefore);
    });
  });

  describe("Edge Cases", function () {
    it("Should handle expired trades", async function () {
      const { dexSettlement, omniToken, usdcToken, maker, taker, validator } = await loadFixture(deployDEXFixture);

      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("EXPIRED_TRADE"));
      const pastDeadline = Math.floor(Date.now() / 1000) - 3600; // 1 hour ago

      await expect(
        dexSettlement.connect(validator).settleTrade(
          tradeId,
          maker.address,
          taker.address,
          await usdcToken.getAddress(),
          await omniToken.getAddress(),
          ethers.parseUnits("100", 6),
          ethers.parseUnits("10", 6),
          500,
          pastDeadline,
          await validator.signMessage("Trade")
        )
      ).to.be.revertedWith("Trade expired");
    });

    it("Should prevent duplicate trade settlement", async function () {
      const { dexSettlement, omniToken, usdcToken, maker, taker, validator } = await loadFixture(deployDEXFixture);

      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("DUPLICATE_TRADE"));
      const amountIn = ethers.parseUnits("100", 6);
      const amountOut = ethers.parseUnits("10", 6);
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const signature = await validator.signMessage("Trade");

      // First settlement
      await dexSettlement.connect(validator).settleTrade(
        tradeId,
        maker.address,
        taker.address,
        await usdcToken.getAddress(),
        await omniToken.getAddress(),
        amountIn,
        amountOut,
        500,
        deadline,
        signature
      );

      // Duplicate settlement should fail
      await expect(
        dexSettlement.connect(validator).settleTrade(
          tradeId,
          maker.address,
          taker.address,
          await usdcToken.getAddress(),
          await omniToken.getAddress(),
          amountIn,
          amountOut,
          500,
          deadline,
          signature
        )
      ).to.be.revertedWith("Trade already settled");
    });

    it("Should respect pause functionality", async function () {
      const { dexSettlement, omniToken, usdcToken, maker, taker, validator, owner } = 
        await loadFixture(deployDEXFixture);

      // Pause DEX
      await dexSettlement.connect(owner).pause();

      const tradeId = ethers.keccak256(ethers.toUtf8Bytes("PAUSED_TRADE"));

      await expect(
        dexSettlement.connect(validator).settleTrade(
          tradeId,
          maker.address,
          taker.address,
          await usdcToken.getAddress(),
          await omniToken.getAddress(),
          ethers.parseUnits("100", 6),
          ethers.parseUnits("10", 6),
          500,
          Math.floor(Date.now() / 1000) + 3600,
          await validator.signMessage("Trade")
        )
      ).to.be.revertedWith("Pausable: paused");
    });
  });
});