const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("OmniPrivacyBridge", function () {
  let omniCoin, privateOmniCoin, bridge;
  let owner, operator, feeManager, user1, user2, user3;

  const INITIAL_SUPPLY = ethers.parseEther("1000000000"); // 1 billion
  const MAX_CONVERSION = ethers.parseEther("10000000"); // 10 million (initial limit)
  const MIN_CONVERSION = ethers.parseUnits("1", 15); // 0.001 tokens
  const PRIVACY_FEE_BPS = 30n; // 0.3%
  const BPS_DENOMINATOR = 10000n;

  beforeEach(async function () {
    [owner, operator, feeManager, user1, user2, user3] = await ethers.getSigners();

    // Deploy OmniCoin (XOM)
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    omniCoin = await OmniCoin.deploy();
    await omniCoin.initialize();

    // Deploy PrivateOmniCoin (pXOM) via UUPS proxy
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    privateOmniCoin = await upgrades.deployProxy(
      PrivateOmniCoin,
      [],
      { initializer: "initialize", kind: "uups" }
    );

    // Deploy OmniPrivacyBridge via UUPS proxy
    const Bridge = await ethers.getContractFactory("OmniPrivacyBridge");
    bridge = await upgrades.deployProxy(
      Bridge,
      [await omniCoin.getAddress(), await privateOmniCoin.getAddress()],
      { initializer: "initialize", kind: "uups" }
    );

    // Grant bridge the MINTER_ROLE on PrivateOmniCoin
    const MINTER_ROLE = await privateOmniCoin.MINTER_ROLE();
    await privateOmniCoin.grantRole(MINTER_ROLE, await bridge.getAddress());

    // Grant bridge the BURNER_ROLE on PrivateOmniCoin
    const BURNER_ROLE = await privateOmniCoin.BURNER_ROLE();
    await privateOmniCoin.grantRole(BURNER_ROLE, await bridge.getAddress());

    // Grant operator role to operator account
    const OPERATOR_ROLE = await bridge.OPERATOR_ROLE();
    await bridge.grantRole(OPERATOR_ROLE, operator.address);

    // Grant fee manager role to feeManager account
    const FEE_MANAGER_ROLE = await bridge.FEE_MANAGER_ROLE();
    await bridge.grantRole(FEE_MANAGER_ROLE, feeManager.address);

    // Mint some XOM to users for testing (keep within uint64 max: ~18.4 ether)
    const MINTER_ROLE_XOM = await omniCoin.MINTER_ROLE();
    await omniCoin.grantRole(MINTER_ROLE_XOM, owner.address);
    await omniCoin.mint(user1.address, ethers.parseEther("15"));
    await omniCoin.mint(user2.address, ethers.parseEther("15"));
    await omniCoin.mint(user3.address, ethers.parseEther("15"));

    // Transfer some XOM to bridge for initial liquidity
    await omniCoin.transfer(await bridge.getAddress(), ethers.parseEther("100"));
  });

  describe("Deployment and Initialization", function () {
    it("Should set correct token addresses", async function () {
      expect(await bridge.omniCoin()).to.equal(await omniCoin.getAddress());
      expect(await bridge.privateOmniCoin()).to.equal(await privateOmniCoin.getAddress());
    });

    it("Should set correct initial max conversion limit", async function () {
      expect(await bridge.maxConversionLimit()).to.equal(MAX_CONVERSION);
    });

    it("Should set up roles correctly", async function () {
      const DEFAULT_ADMIN_ROLE = await bridge.DEFAULT_ADMIN_ROLE();
      const OPERATOR_ROLE = await bridge.OPERATOR_ROLE();
      const FEE_MANAGER_ROLE = await bridge.FEE_MANAGER_ROLE();

      expect(await bridge.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
      expect(await bridge.hasRole(OPERATOR_ROLE, operator.address)).to.be.true;
      expect(await bridge.hasRole(FEE_MANAGER_ROLE, feeManager.address)).to.be.true;
    });

    it("Should initialize with zero locked and converted amounts", async function () {
      expect(await bridge.totalLocked()).to.equal(0);
      expect(await bridge.totalConvertedToPrivate()).to.equal(0);
      expect(await bridge.totalConvertedToPublic()).to.equal(0);
    });

    it("Should revert initialization with zero address for OmniCoin", async function () {
      const Bridge = await ethers.getContractFactory("OmniPrivacyBridge");
      await expect(
        upgrades.deployProxy(
          Bridge,
          [ethers.ZeroAddress, await privateOmniCoin.getAddress()],
          { initializer: "initialize", kind: "uups" }
        )
      ).to.be.revertedWithCustomError(Bridge, "ZeroAddress");
    });

    it("Should revert initialization with zero address for PrivateOmniCoin", async function () {
      const Bridge = await ethers.getContractFactory("OmniPrivacyBridge");
      await expect(
        upgrades.deployProxy(
          Bridge,
          [await omniCoin.getAddress(), ethers.ZeroAddress],
          { initializer: "initialize", kind: "uups" }
        )
      ).to.be.revertedWithCustomError(Bridge, "ZeroAddress");
    });
  });

  describe("XOM to pXOM Conversion (convertXOMtoPXOM)", function () {
    it("Should convert XOM to pXOM with 0.3% fee", async function () {
      const amount = ethers.parseEther("1");
      const fee = (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const amountAfterFee = amount - fee;

      // Approve bridge to spend XOM
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amount);

      // Convert XOM to pXOM
      await expect(bridge.connect(user1).convertXOMtoPXOM(amount))
        .to.emit(bridge, "ConvertedToPrivate")
        .withArgs(user1.address, amount, amountAfterFee, fee);

      // Check balances
      expect(await privateOmniCoin.balanceOf(user1.address)).to.equal(amountAfterFee);

      // Check statistics - totalLocked tracks amountAfterFee, fees tracked separately
      expect(await bridge.totalLocked()).to.equal(amountAfterFee);
      expect(await bridge.totalConvertedToPrivate()).to.equal(amount);
    });

    it("Should fail conversion with zero amount", async function () {
      await expect(
        bridge.connect(user1).convertXOMtoPXOM(0)
      ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
    });

    it("Should fail conversion below minimum", async function () {
      const tooSmall = ethers.parseUnits("1", 14); // 0.0001 tokens
      await omniCoin.connect(user1).approve(await bridge.getAddress(), tooSmall);

      await expect(
        bridge.connect(user1).convertXOMtoPXOM(tooSmall)
      ).to.be.revertedWithCustomError(bridge, "BelowMinimum");
    });

    it("Should fail conversion exceeding max conversion limit", async function () {
      // Default limit is 10 million tokens
      const tooLarge = ethers.parseEther("20000000"); // 20 million (> 10M limit)

      await expect(
        bridge.connect(user1).convertXOMtoPXOM(tooLarge)
      ).to.be.revertedWithCustomError(bridge, "ExceedsConversionLimit");
    });

    it("Should fail conversion exceeding configured limit", async function () {
      // Lower the limit first
      await bridge.setMaxConversionLimit(ethers.parseEther("5"));

      const tooLarge = ethers.parseEther("10"); // 10 ether (> 5 ether limit)
      await omniCoin.connect(user1).approve(await bridge.getAddress(), tooLarge);

      await expect(
        bridge.connect(user1).convertXOMtoPXOM(tooLarge)
      ).to.be.revertedWithCustomError(bridge, "ExceedsConversionLimit");
    });

    it("Should fail conversion without approval", async function () {
      const amount = ethers.parseEther("1");

      await expect(
        bridge.connect(user1).convertXOMtoPXOM(amount)
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientAllowance");
    });

    it("Should handle multiple conversions correctly", async function () {
      const amount1 = ethers.parseEther("1");
      const amount2 = ethers.parseEther("2");
      const fee1 = (amount1 * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const fee2 = (amount2 * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;

      // First conversion
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amount1);
      await bridge.connect(user1).convertXOMtoPXOM(amount1);

      // Second conversion
      await omniCoin.connect(user2).approve(await bridge.getAddress(), amount2);
      await bridge.connect(user2).convertXOMtoPXOM(amount2);

      // Check total locked (tracks amountAfterFee, not full amounts)
      const expectedLocked = (amount1 - fee1) + (amount2 - fee2);
      expect(await bridge.totalLocked()).to.equal(expectedLocked);
      expect(await bridge.totalConvertedToPrivate()).to.equal(amount1 + amount2);
    });
  });

  describe("pXOM to XOM Conversion (convertPXOMtoXOM)", function () {
    beforeEach(async function () {
      // Convert some XOM to pXOM first
      const amount = ethers.parseEther("10");
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amount);
      await bridge.connect(user1).convertXOMtoPXOM(amount);
    });

    it("Should convert pXOM to XOM with no fee", async function () {
      const amount = ethers.parseEther("1");

      // Approve bridge to burn pXOM
      await privateOmniCoin.connect(user1).approve(await bridge.getAddress(), amount);

      const initialXomBalance = await omniCoin.balanceOf(user1.address);

      // Convert pXOM to XOM
      await expect(bridge.connect(user1).convertPXOMtoXOM(amount))
        .to.emit(bridge, "ConvertedToPublic")
        .withArgs(user1.address, amount);

      // Check XOM balance increased by full amount (no fee)
      expect(await omniCoin.balanceOf(user1.address)).to.equal(initialXomBalance + amount);

      // Check pXOM balance decreased
      const fee = (ethers.parseEther("10") * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const expectedPxomBalance = ethers.parseEther("10") - fee - amount;
      expect(await privateOmniCoin.balanceOf(user1.address)).to.be.closeTo(expectedPxomBalance, ethers.parseEther("0.001"));
    });

    it("Should fail conversion with zero amount", async function () {
      await expect(
        bridge.connect(user1).convertPXOMtoXOM(0)
      ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
    });

    it("Should fail conversion below minimum", async function () {
      const tooSmall = ethers.parseUnits("1", 14); // 0.0001 tokens

      await expect(
        bridge.connect(user1).convertPXOMtoXOM(tooSmall)
      ).to.be.revertedWithCustomError(bridge, "BelowMinimum");
    });

    it("Should fail conversion exceeding locked funds", async function () {
      const amount = ethers.parseEther("15"); // More than locked

      await expect(
        bridge.connect(user1).convertPXOMtoXOM(amount)
      ).to.be.revertedWithCustomError(bridge, "InsufficientLockedFunds");
    });

    it("Should update statistics correctly", async function () {
      const amount = ethers.parseEther("1");
      const initialLocked = await bridge.totalLocked();

      await privateOmniCoin.connect(user1).approve(await bridge.getAddress(), amount);
      await bridge.connect(user1).convertPXOMtoXOM(amount);

      expect(await bridge.totalLocked()).to.equal(initialLocked - amount);
      expect(await bridge.totalConvertedToPublic()).to.equal(amount);
    });
  });

  describe("View Functions", function () {
    it("Should return correct conversion rate", async function () {
      expect(await bridge.getConversionRate()).to.equal(ethers.parseEther("1")); // 1:1
    });

    it("Should preview convert to private correctly", async function () {
      const amount = ethers.parseEther("1");
      const expectedFee = (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const expectedOut = amount - expectedFee;

      const [amountOut, fee] = await bridge.previewConvertToPrivate(amount);

      expect(amountOut).to.equal(expectedOut);
      expect(fee).to.equal(expectedFee);
    });

    it("Should preview convert to public correctly", async function () {
      const amount = ethers.parseEther("1");

      const amountOut = await bridge.previewConvertToPublic(amount);

      expect(amountOut).to.equal(amount); // No fee
    });

    it("Should return correct bridge statistics", async function () {
      // Convert some tokens
      const amount = ethers.parseEther("5");
      const fee = (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const amountAfterFee = amount - fee;
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amount);
      await bridge.connect(user1).convertXOMtoPXOM(amount);

      const [totalLocked, totalToPrivate, totalToPublic] = await bridge.getBridgeStats();

      expect(totalLocked).to.equal(amountAfterFee); // tracks amountAfterFee
      expect(totalToPrivate).to.equal(amount); // tracks full amount
      expect(totalToPublic).to.equal(0);
    });
  });

  describe("Admin Functions - setMaxConversionLimit", function () {
    it("Should allow admin to update max conversion limit", async function () {
      const newLimit = ethers.parseEther("15");

      await expect(bridge.setMaxConversionLimit(newLimit))
        .to.emit(bridge, "MaxConversionLimitUpdated")
        .withArgs(MAX_CONVERSION, newLimit);

      expect(await bridge.maxConversionLimit()).to.equal(newLimit);
    });

    it("Should fail to set zero limit", async function () {
      await expect(
        bridge.setMaxConversionLimit(0)
      ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
    });

    it("Should allow setting very large conversion limit (no upper bound)", async function () {
      const veryLarge = ethers.parseEther("1000000000"); // 1 billion

      await bridge.setMaxConversionLimit(veryLarge);

      expect(await bridge.maxConversionLimit()).to.equal(veryLarge);
    });

    it("Should fail when called by non-admin", async function () {
      const newLimit = ethers.parseEther("15");

      await expect(
        bridge.connect(user1).setMaxConversionLimit(newLimit)
      ).to.be.revertedWithCustomError(bridge, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Admin Functions - Pause/Unpause", function () {
    it("Should allow operator to pause", async function () {
      await bridge.connect(operator).pause();
      expect(await bridge.paused()).to.be.true;
    });

    it("Should allow operator to unpause", async function () {
      await bridge.connect(operator).pause();
      await bridge.connect(operator).unpause();
      expect(await bridge.paused()).to.be.false;
    });

    it("Should block conversions when paused", async function () {
      await bridge.connect(operator).pause();

      const amount = ethers.parseEther("1");
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amount);

      await expect(
        bridge.connect(user1).convertXOMtoPXOM(amount)
      ).to.be.revertedWithCustomError(bridge, "EnforcedPause");
    });

    it("Should fail pause when called by non-operator", async function () {
      await expect(
        bridge.connect(user1).pause()
      ).to.be.revertedWithCustomError(bridge, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Admin Functions - Emergency Withdrawal", function () {
    it("Should allow admin to emergency withdraw tokens", async function () {
      const amount = ethers.parseEther("1");
      const bridgeAddress = await bridge.getAddress();
      const initialBalance = await omniCoin.balanceOf(bridgeAddress);

      await expect(bridge.emergencyWithdraw(await omniCoin.getAddress(), user3.address, amount))
        .to.emit(bridge, "EmergencyWithdrawal")
        .withArgs(await omniCoin.getAddress(), user3.address, amount);

      expect(await omniCoin.balanceOf(bridgeAddress)).to.equal(initialBalance - amount);
      expect(await omniCoin.balanceOf(user3.address)).to.be.gte(amount);
    });

    it("Should fail emergency withdraw with zero address recipient", async function () {
      const amount = ethers.parseEther("1");

      await expect(
        bridge.emergencyWithdraw(await omniCoin.getAddress(), ethers.ZeroAddress, amount)
      ).to.be.revertedWithCustomError(bridge, "ZeroAddress");
    });

    it("Should fail emergency withdraw with zero amount", async function () {
      await expect(
        bridge.emergencyWithdraw(await omniCoin.getAddress(), user3.address, 0)
      ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
    });

    it("Should fail emergency withdraw when called by non-admin", async function () {
      const amount = ethers.parseEther("1");

      await expect(
        bridge.connect(user1).emergencyWithdraw(await omniCoin.getAddress(), user3.address, amount)
      ).to.be.revertedWithCustomError(bridge, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Integration Tests", function () {
    it("Should handle full conversion cycle (XOM -> pXOM -> XOM)", async function () {
      const amount = ethers.parseEther("10");
      const initialXomBalance = await omniCoin.balanceOf(user1.address);

      // Convert XOM to pXOM
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amount);
      await bridge.connect(user1).convertXOMtoPXOM(amount);

      const fee = (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const pxomAmount = amount - fee;

      // Convert pXOM back to XOM
      await privateOmniCoin.connect(user1).approve(await bridge.getAddress(), pxomAmount);
      await bridge.connect(user1).convertPXOMtoXOM(pxomAmount);

      // Check final balance (should have lost fee amount)
      const finalBalance = await omniCoin.balanceOf(user1.address);
      expect(finalBalance).to.equal(initialXomBalance - fee);
    });

    it("Should handle conversions from multiple users", async function () {
      const amounts = [
        ethers.parseEther("1"),
        ethers.parseEther("2"),
        ethers.parseEther("3")
      ];

      // Convert from all users
      await omniCoin.connect(user1).approve(await bridge.getAddress(), amounts[0]);
      await bridge.connect(user1).convertXOMtoPXOM(amounts[0]);

      await omniCoin.connect(user2).approve(await bridge.getAddress(), amounts[1]);
      await bridge.connect(user2).convertXOMtoPXOM(amounts[1]);

      await omniCoin.connect(user3).approve(await bridge.getAddress(), amounts[2]);
      await bridge.connect(user3).convertXOMtoPXOM(amounts[2]);

      // Check total locked (tracks amountAfterFee for each conversion)
      const totalAmount = amounts[0] + amounts[1] + amounts[2];
      const totalFees = (totalAmount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      expect(await bridge.totalLocked()).to.equal(totalAmount - totalFees);
    });
  });

  describe("Edge Cases", function () {
    it("Should handle large conversion correctly", async function () {
      const maxAmount = ethers.parseEther("15"); // Within user balance
      await bridge.setMaxConversionLimit(maxAmount);

      await omniCoin.connect(user1).approve(await bridge.getAddress(), maxAmount);
      await bridge.connect(user1).convertXOMtoPXOM(maxAmount);

      // Should succeed - totalLocked tracks amountAfterFee
      const fee = (maxAmount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      expect(await bridge.totalLocked()).to.equal(maxAmount - fee);
    });

    it("Should handle minimum conversion correctly", async function () {
      const minAmount = MIN_CONVERSION;

      await omniCoin.connect(user1).approve(await bridge.getAddress(), minAmount);
      await bridge.connect(user1).convertXOMtoPXOM(minAmount);

      // Should succeed - totalLocked tracks amountAfterFee
      const fee = (minAmount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      expect(await bridge.totalLocked()).to.equal(minAmount - fee);
    });

    it("Should maintain accurate statistics across many operations", async function () {
      const convertAmount = ethers.parseEther("1");
      const revertAmount = ethers.parseEther("0.5");
      const fee = (convertAmount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
      const lockedAfterConvert = convertAmount - fee; // amountAfterFee

      // Convert XOM to pXOM
      await omniCoin.connect(user1).approve(await bridge.getAddress(), convertAmount);
      await bridge.connect(user1).convertXOMtoPXOM(convertAmount);

      // Convert some pXOM back to XOM
      await privateOmniCoin.connect(user1).approve(await bridge.getAddress(), revertAmount);
      await bridge.connect(user1).convertPXOMtoXOM(revertAmount);

      // Check statistics
      const [totalLocked, totalToPrivate, totalToPublic] = await bridge.getBridgeStats();
      expect(totalLocked).to.equal(lockedAfterConvert - revertAmount);
      expect(totalToPrivate).to.equal(convertAmount);
      expect(totalToPublic).to.equal(revertAmount);
    });
  });
});
