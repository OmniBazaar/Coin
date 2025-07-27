const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinBridge Privacy Functions", function () {
  // Test fixture
  async function deployBridgeFixture() {
    const [owner, user1, user2, validator, treasury, development] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("contracts/MockERC20.sol:MockERC20");
    const omniToken = await MockERC20.deploy("OmniCoin", "OMNI", 6);
    const cotiToken = await MockERC20.deploy("COTI", "COTI", 18);
    await omniToken.waitForDeployment();
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

    // Deploy OmniCoinBridge
    const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
    const bridge = await OmniCoinBridge.deploy(
      await omniToken.getAddress(),
      await registry.getAddress(),
      await privacyFeeManager.getAddress()
    );
    await bridge.waitForDeployment();

    // Set up fee distribution
    await bridge.setFeeDistribution(
      treasury.address,
      development.address,
      7000, // 70% validators
      2000, // 20% treasury
      1000  // 10% development
    );

    // Grant necessary roles
    await bridge.grantRole(await bridge.BRIDGE_VALIDATOR_ROLE(), validator.address);
    await privacyFeeManager.grantRole(await privacyFeeManager.FEE_MANAGER_ROLE(), await bridge.getAddress());

    // Mint tokens
    const mintAmount = ethers.parseUnits("100000", 6);
    await omniToken.mint(user1.address, mintAmount);
    await omniToken.mint(user2.address, mintAmount);

    // Approve bridge and fee manager
    await omniToken.connect(user1).approve(await bridge.getAddress(), ethers.MaxUint256);
    await omniToken.connect(user2).approve(await bridge.getAddress(), ethers.MaxUint256);
    await omniToken.connect(user1).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(user2).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);

    // Enable privacy preferences
    await omniToken.connect(user1).setPrivacyPreference(true);
    await omniToken.connect(user2).setPrivacyPreference(true);

    return {
      bridge,
      omniToken,
      privacyFeeManager,
      registry,
      owner,
      user1,
      user2,
      validator,
      treasury,
      development
    };
  }

  describe("Public Bridge Operations (No Privacy)", function () {
    it("Should bridge tokens publicly without privacy fees", async function () {
      const { bridge, omniToken, user1 } = await loadFixture(deployBridgeFixture);

      const bridgeAmount = ethers.parseUnits("1000", 6);
      const targetChain = 137; // Polygon
      const targetAddress = "0x1234567890123456789012345678901234567890";

      const initialBalance = await omniToken.balanceOf(user1.address);

      // Bridge tokens publicly
      await expect(bridge.connect(user1).bridgeTokens(
        bridgeAmount,
        targetChain,
        targetAddress
      )).to.emit(bridge, "TokensBridged")
        .withArgs(user1.address, bridgeAmount, targetChain, targetAddress, false);

      // Verify tokens were locked
      const finalBalance = await omniToken.balanceOf(user1.address);
      expect(initialBalance - finalBalance).to.equal(bridgeAmount);
    });

    it("Should complete public bridge operations", async function () {
      const { bridge, omniToken, user1, user2, validator } = await loadFixture(deployBridgeFixture);

      const bridgeAmount = ethers.parseUnits("500", 6);
      const sourceChain = 137; // Polygon
      const txHash = ethers.keccak256(ethers.toUtf8Bytes("TX_001"));

      // Complete bridge (mint tokens)
      await expect(bridge.connect(validator).completeBridge(
        user2.address,
        bridgeAmount,
        sourceChain,
        txHash
      )).to.emit(bridge, "BridgeCompleted")
        .withArgs(user2.address, bridgeAmount, sourceChain, txHash);

      // Verify tokens were minted
      const balance = await omniToken.balanceOf(user2.address);
      expect(balance).to.be.gt(ethers.parseUnits("100000", 6));
    });
  });

  describe("Private Bridge Operations (With Privacy)", function () {
    it("Should bridge tokens privately with privacy credits", async function () {
      const { bridge, omniToken, privacyFeeManager, user1 } = await loadFixture(deployBridgeFixture);

      // Pre-deposit privacy credits
      const creditAmount = ethers.parseUnits("1000", 6);
      await privacyFeeManager.connect(user1).depositPrivacyCredits(creditAmount);

      const bridgeAmount = ethers.parseUnits("1000", 6);
      const targetChain = 137;
      const targetAddress = "0x1234567890123456789012345678901234567890";

      // Calculate expected privacy fee
      const baseFee = await bridge.calculateBridgeFee(bridgeAmount);
      const privacyFee = baseFee * 10n; // 10x multiplier

      const initialCredits = await privacyFeeManager.getPrivacyCredits(user1.address);
      const initialBalance = await omniToken.balanceOf(user1.address);

      // Bridge tokens privately
      await expect(bridge.connect(user1).bridgeTokensWithPrivacy(
        bridgeAmount,
        targetChain,
        targetAddress,
        true // use privacy
      )).to.emit(bridge, "TokensBridged")
        .withArgs(user1.address, bridgeAmount, targetChain, targetAddress, true);

      // Verify privacy credits were deducted
      const finalCredits = await privacyFeeManager.getPrivacyCredits(user1.address);
      expect(initialCredits - finalCredits).to.equal(privacyFee);

      // Verify tokens were locked
      const finalBalance = await omniToken.balanceOf(user1.address);
      expect(initialBalance - finalBalance).to.equal(bridgeAmount);
    });

    it("Should fail if insufficient privacy credits", async function () {
      const { bridge, privacyFeeManager, user1 } = await loadFixture(deployBridgeFixture);

      // Deposit small amount of credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("1", 6));

      const bridgeAmount = ethers.parseUnits("10000", 6); // Large amount
      const targetChain = 137;
      const targetAddress = "0x1234567890123456789012345678901234567890";

      // Attempt private bridge
      await expect(
        bridge.connect(user1).bridgeTokensWithPrivacy(
          bridgeAmount,
          targetChain,
          targetAddress,
          true
        )
      ).to.be.revertedWith("Insufficient privacy credits");
    });

    it("Should handle encrypted amounts for private bridges", async function () {
      const { bridge, privacyFeeManager, user1, owner } = await loadFixture(deployBridgeFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      // Enable MPC for testing encrypted amounts
      await bridge.connect(owner).setMpcAvailability(true);

      const bridgeAmount = ethers.parseUnits("1000", 6);
      const targetChain = 137;
      const targetAddress = "0x1234567890123456789012345678901234567890";

      // In production, this would use actual MPC encryption
      // For testing, we simulate the privacy flow
      await expect(bridge.connect(user1).bridgeTokensWithPrivacy(
        bridgeAmount,
        targetChain,
        targetAddress,
        true
      )).to.emit(bridge, "TokensBridged");
    });
  });

  describe("Fee Distribution", function () {
    it("Should distribute bridge fees correctly", async function () {
      const { bridge, omniToken, privacyFeeManager, user1, treasury, development, owner } = 
        await loadFixture(deployBridgeFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      // Enable fees
      await bridge.connect(owner).setBridgeFee(10); // 0.1%

      const bridgeAmount = ethers.parseUnits("10000", 6);

      // Bridge with privacy (generates fees)
      await bridge.connect(user1).bridgeTokensWithPrivacy(
        bridgeAmount,
        137,
        "0x1234567890123456789012345678901234567890",
        true
      );

      // Check fee accumulation
      const accumulatedFees = await bridge.accumulatedFees();
      expect(accumulatedFees).to.be.gt(0);

      // Distribute fees
      const treasuryBefore = await omniToken.balanceOf(treasury.address);
      const developmentBefore = await omniToken.balanceOf(development.address);

      await bridge.connect(owner).distributeFees();

      const treasuryAfter = await omniToken.balanceOf(treasury.address);
      const developmentAfter = await omniToken.balanceOf(development.address);

      // Verify distribution (20% treasury, 10% development)
      expect(treasuryAfter).to.be.gt(treasuryBefore);
      expect(developmentAfter).to.be.gt(developmentBefore);
    });
  });

  describe("Cross-Chain Privacy", function () {
    it("Should maintain privacy across chains", async function () {
      const { bridge, privacyFeeManager, user1, user2, validator } = await loadFixture(deployBridgeFixture);

      // User1 bridges privately from source chain
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("1000", 6));
      
      const bridgeAmount = ethers.parseUnits("500", 6);
      await bridge.connect(user1).bridgeTokensWithPrivacy(
        bridgeAmount,
        137,
        user2.address,
        true
      );

      // Validator completes bridge on destination
      const txHash = ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_TX_001"));
      
      // Complete with privacy flag
      await expect(bridge.connect(validator).completeBridgeWithPrivacy(
        user2.address,
        bridgeAmount,
        1, // Ethereum
        txHash,
        true // maintain privacy
      )).to.emit(bridge, "BridgeCompleted");
    });
  });

  describe("Privacy Edge Cases", function () {
    it("Should handle zero amount bridges", async function () {
      const { bridge, user1 } = await loadFixture(deployBridgeFixture);

      // Zero amount should fail
      await expect(
        bridge.connect(user1).bridgeTokens(
          0,
          137,
          "0x1234567890123456789012345678901234567890"
        )
      ).to.be.revertedWith("Amount must be greater than 0");
    });

    it("Should respect pause functionality", async function () {
      const { bridge, user1, owner } = await loadFixture(deployBridgeFixture);

      // Pause bridge
      await bridge.connect(owner).pause();

      // Try to bridge while paused
      await expect(
        bridge.connect(user1).bridgeTokens(
          ethers.parseUnits("1000", 6),
          137,
          "0x1234567890123456789012345678901234567890"
        )
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should handle chain limits", async function () {
      const { bridge, user1, owner } = await loadFixture(deployBridgeFixture);

      // Set chain limit
      await bridge.connect(owner).setChainLimit(137, ethers.parseUnits("100", 6));

      // Try to bridge more than limit
      await expect(
        bridge.connect(user1).bridgeTokens(
          ethers.parseUnits("1000", 6),
          137,
          "0x1234567890123456789012345678901234567890"
        )
      ).to.be.revertedWith("Exceeds chain limit");
    });
  });

  describe("Batch Bridge Operations", function () {
    it("Should handle batch bridges with mixed privacy", async function () {
      const { bridge, privacyFeeManager, user1 } = await loadFixture(deployBridgeFixture);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(user1).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      const amounts = [
        ethers.parseUnits("100", 6),
        ethers.parseUnits("200", 6),
        ethers.parseUnits("300", 6)
      ];
      const targetChains = [137, 56, 43114]; // Polygon, BSC, Avalanche
      const targetAddresses = [
        "0x1111111111111111111111111111111111111111",
        "0x2222222222222222222222222222222222222222",
        "0x3333333333333333333333333333333333333333"
      ];
      const usePrivacy = [false, true, false]; // Mixed privacy

      // Execute batch bridge
      await expect(bridge.connect(user1).batchBridge(
        amounts,
        targetChains,
        targetAddresses,
        usePrivacy
      )).to.emit(bridge, "BatchBridgeCompleted");

      // Verify privacy credits were only deducted for private bridges
      const stats = await privacyFeeManager.getUserPrivacyStats(user1.address);
      expect(stats.usage).to.equal(1); // Only one private bridge
    });
  });

  describe("Emergency Recovery", function () {
    it("Should allow emergency token recovery", async function () {
      const { bridge, omniToken, user1, owner } = await loadFixture(deployBridgeFixture);

      // Bridge tokens
      const bridgeAmount = ethers.parseUnits("1000", 6);
      await bridge.connect(user1).bridgeTokens(
        bridgeAmount,
        137,
        "0x1234567890123456789012345678901234567890"
      );

      // Emergency recovery (only in extreme cases)
      const bridgeBalance = await omniToken.balanceOf(await bridge.getAddress());
      expect(bridgeBalance).to.be.gt(0);

      // In production, this would require multi-sig or DAO approval
      await bridge.connect(owner).emergencyWithdraw(
        await omniToken.getAddress(),
        bridgeBalance,
        owner.address
      );

      const finalBridgeBalance = await omniToken.balanceOf(await bridge.getAddress());
      expect(finalBridgeBalance).to.equal(0);
    });
  });
});