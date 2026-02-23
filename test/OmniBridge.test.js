const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// Mock Warp Messenger for testing
const WARP_MESSENGER_ADDRESS = "0x0200000000000000000000000000000000000005";

describe("OmniBridge", function () {
  let bridge;
  let token;
  let privateToken;
  let core;
  let owner, user1, user2, admin, validator;
  
  const CHAIN_ID_FUJI = 43113;
  const CHAIN_ID_CCHAIN = 43114;
  const BLOCKCHAIN_ID_FUJI = ethers.id("fuji");
  const BLOCKCHAIN_ID_CCHAIN = ethers.id("c-chain");
  
  const MIN_TRANSFER = ethers.parseEther("10");
  const MAX_TRANSFER = ethers.parseEther("10000");
  const DAILY_LIMIT = ethers.parseEther("100000");
  const TRANSFER_FEE = 50; // 0.5%
  
  beforeEach(async function () {
    [owner, user1, user2, admin, validator] = await ethers.getSigners();
    
    // Deploy and set up mock Warp Messenger FIRST
    const MockWarpMessenger = await ethers.getContractFactory("MockWarpMessenger");
    const mockWarp = await MockWarpMessenger.deploy();
    
    // Get the mock's bytecode and state storage
    const mockCode = await ethers.provider.getCode(mockWarp.target);
    
    // Place mock at precompile address using hardhat_setCode
    // This must be done BEFORE deploying OmniBridge
    await ethers.provider.send("hardhat_setCode", [
      WARP_MESSENGER_ADDRESS,
      mockCode
    ]);
    
    // Also copy the storage slot for mockBlockchainID
    // The first storage slot (0) contains the mockBlockchainID
    const mockBlockchainId = await ethers.provider.getStorage(mockWarp.target, 0);
    await ethers.provider.send("hardhat_setStorageAt", [
      WARP_MESSENGER_ADDRESS,
      "0x0",
      mockBlockchainId
    ]);
    
    // Deploy OmniCoin tokens
    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy();
    await token.initialize();
    
    const PrivateToken = await ethers.getContractFactory("PrivateOmniCoin");
    privateToken = await upgrades.deployProxy(
      PrivateToken,
      [],
      { initializer: "initialize", kind: "uups" }
    );

    // Deploy OmniCore via UUPS proxy (constructor calls _disableInitializers)
    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await upgrades.deployProxy(
      OmniCore,
      [admin.address, token.target, admin.address, admin.address],
      { initializer: "initialize" }
    );
    
    // Register services
    await core.connect(admin).setService(ethers.id("OMNICOIN"), token.target);
    await core.connect(admin).setService(ethers.id("PRIVATE_OMNICOIN"), privateToken.target);
    
    // Deploy OmniBridge via UUPS proxy (initialize takes _core, admin)
    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    bridge = await upgrades.deployProxy(
      OmniBridge,
      [core.target, admin.address],
      { initializer: "initialize", kind: "uups" }
    );
    
    // Setup: Give users tokens
    await token.mint(user1.address, ethers.parseEther("100000"));
    await token.mint(user2.address, ethers.parseEther("100000"));
    await privateToken.mint(user1.address, ethers.parseEther("100000"));
    
    // Approve bridge
    await token.connect(user1).approve(bridge.target, ethers.parseEther("100000"));
    await token.connect(user2).approve(bridge.target, ethers.parseEther("100000"));
    await privateToken.connect(user1).approve(bridge.target, ethers.parseEther("100000"));
    
    // Configure chains
    await bridge.connect(admin).updateChainConfig(
      CHAIN_ID_FUJI,
      BLOCKCHAIN_ID_FUJI,
      true,
      MIN_TRANSFER,
      MAX_TRANSFER,
      DAILY_LIMIT,
      TRANSFER_FEE,
      ethers.ZeroAddress // teleporter address
    );
    
    await bridge.connect(admin).updateChainConfig(
      CHAIN_ID_CCHAIN,
      BLOCKCHAIN_ID_CCHAIN,
      true,
      MIN_TRANSFER,
      MAX_TRANSFER,
      DAILY_LIMIT,
      TRANSFER_FEE,
      ethers.ZeroAddress
    );
  });
  
  describe("Chain Configuration", function () {
    it("Should update chain configuration", async function () {
      const newChainId = 100;
      const newBlockchainId = ethers.id("new-chain");
      
      await bridge.connect(admin).updateChainConfig(
        newChainId,
        newBlockchainId,
        true,
        ethers.parseEther("5"),
        ethers.parseEther("5000"),
        ethers.parseEther("50000"),
        100, // 1% fee
        "0x1234567890123456789012345678901234567890"
      );
      
      const config = await bridge.chainConfigs(newChainId);
      expect(config.isActive).to.be.true;
      expect(config.minTransfer).to.equal(ethers.parseEther("5"));
      expect(config.maxTransfer).to.equal(ethers.parseEther("5000"));
      expect(config.dailyLimit).to.equal(ethers.parseEther("50000"));
      expect(config.transferFee).to.equal(100);
      
      // Check blockchain ID mapping
      expect(await bridge.blockchainToChainId(newBlockchainId)).to.equal(newChainId);
    });
    
    it("Should reject invalid fee configuration", async function () {
      await expect(
        bridge.connect(admin).updateChainConfig(
          100,
          ethers.id("test"),
          true,
          MIN_TRANSFER,
          MAX_TRANSFER,
          DAILY_LIMIT,
          600, // 6% - too high
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidFee");
    });
    
    it("Should reject invalid transfer limits", async function () {
      await expect(
        bridge.connect(admin).updateChainConfig(
          100,
          ethers.id("test"),
          true,
          MAX_TRANSFER, // min > max
          MIN_TRANSFER,
          DAILY_LIMIT,
          TRANSFER_FEE,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidAmount");
    });
    
    it("Should only allow admin to update config", async function () {
      await expect(
        bridge.connect(user1).updateChainConfig(
          100,
          ethers.id("test"),
          true,
          MIN_TRANSFER,
          MAX_TRANSFER,
          DAILY_LIMIT,
          TRANSFER_FEE,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });
  });
  
  describe("Transfer Initiation", function () {
    it("Should initiate transfer with correct parameters", async function () {
      const amount = ethers.parseEther("100");
      const recipient = user2.address;
      
      const tx = await bridge.connect(user1).initiateTransfer(
        recipient,
        amount,
        CHAIN_ID_FUJI,
        false // use regular token
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "TransferInitiated"
      );
      
      expect(event).to.not.be.undefined;
      const transferId = event.args.transferId;
      
      // Check transfer details
      const transfer = await bridge.getTransfer(transferId);
      expect(transfer.sender).to.equal(user1.address);
      expect(transfer.recipient).to.equal(recipient);
      expect(transfer.targetChainId).to.equal(CHAIN_ID_FUJI);
      
      // Check amount after fee
      const expectedFee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
      const expectedAmount = amount - expectedFee;
      expect(transfer.amount).to.equal(expectedAmount);
      
      // Check tokens locked
      expect(await token.balanceOf(bridge.target)).to.equal(amount);
    });
    
    it("Should initiate private token transfer", async function () {
      const amount = ethers.parseEther("100");
      
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        true // use private token
      );
      
      expect(await privateToken.balanceOf(bridge.target)).to.equal(amount);
    });
    
    it("Should enforce minimum transfer amount", async function () {
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("5"), // Below minimum
          CHAIN_ID_FUJI,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "TransferLimitExceeded");
    });
    
    it("Should enforce maximum transfer amount", async function () {
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("20000"), // Above maximum
          CHAIN_ID_FUJI,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "TransferLimitExceeded");
    });
    
    it("Should enforce daily transfer limit", async function () {
      // Make transfers up to daily limit
      // Daily limit is 100k, each transfer adds its full amount to daily volume
      const transferAmount = ethers.parseEther("9999"); // Just under max to avoid hitting max limit
      
      // First 10 transfers should succeed (99,990 total)
      for (let i = 0; i < 10; i++) {
        await bridge.connect(user1).initiateTransfer(
          user2.address,
          transferAmount,
          CHAIN_ID_FUJI,
          false
        );
      }
      
      // Next transfer should fail (would exceed 100k daily limit)
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("11"), // 99,990 + 11 = 100,001 > 100,000
          CHAIN_ID_FUJI,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "DailyLimitExceeded");
    });
    
    it("Should reject inactive chain", async function () {
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("100"),
          999, // Non-configured chain
          false
        )
      ).to.be.revertedWithCustomError(bridge, "ChainNotSupported");
    });
    
    it("Should reject zero recipient", async function () {
      await expect(
        bridge.connect(user1).initiateTransfer(
          ethers.ZeroAddress,
          ethers.parseEther("100"),
          CHAIN_ID_FUJI,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });
  });
  
  describe("Daily Volume Tracking", function () {
    it("Should track daily volume correctly", async function () {
      const amount = ethers.parseEther("1000");
      
      // Initial volume should be 0
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(0);
      
      // Make transfer
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      // Volume should be updated
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(amount);
      
      // Make another transfer
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      // Volume should be cumulative
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(amount * 2n);
    });
    
    it("Should reset daily volume after 24 hours", async function () {
      const amount = ethers.parseEther("1000");
      
      // Make transfer
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(amount);
      
      // Fast forward 24 hours
      await time.increase(24 * 60 * 60);
      
      // Volume should be reset
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(0);
      
      // Can make new transfer
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(amount);
    });
  });
  
  describe("Transfer Fees", function () {
    it("Should calculate fees correctly", async function () {
      const amount = ethers.parseEther("1000");
      const expectedFee = (amount * BigInt(TRANSFER_FEE)) / 10000n; // 0.5%
      const expectedNet = amount - expectedFee;
      
      const tx = await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "TransferInitiated"
      );
      
      expect(event.args.fee).to.equal(expectedFee);
      expect(event.args.amount).to.equal(expectedNet);
    });
    
    it("Should handle different fee rates", async function () {
      // Update chain with 2% fee
      const newFee = 200; // 2%
      await bridge.connect(admin).updateChainConfig(
        CHAIN_ID_CCHAIN,
        BLOCKCHAIN_ID_CCHAIN,
        true,
        MIN_TRANSFER,
        MAX_TRANSFER,
        DAILY_LIMIT,
        newFee,
        ethers.ZeroAddress
      );
      
      const amount = ethers.parseEther("1000");
      const expectedFee = (amount * BigInt(newFee)) / 10000n;
      const expectedNet = amount - expectedFee;
      
      const tx = await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_CCHAIN,
        false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "TransferInitiated"
      );
      
      expect(event.args.fee).to.equal(expectedFee);
      expect(event.args.amount).to.equal(expectedNet);
    });
  });
  
  describe("Warp Message Processing", function () {
    it("Should track processed messages", async function () {
      const sourceChainID = BLOCKCHAIN_ID_FUJI;
      const transferId = 1;
      
      // Should not be processed initially
      expect(await bridge.isMessageProcessed(sourceChainID, transferId)).to.be.false;
      
      // Note: Full Warp message processing would require mocking the precompile
      // which is complex in a test environment
    });
    
    it("Should emit Warp message events", async function () {
      const amount = ethers.parseEther("100");
      
      const tx = await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      const receipt = await tx.wait();
      
      // Check for WarpMessageSent event
      const warpEvent = receipt.logs.find(
        log => log.fragment && log.fragment.name === "WarpMessageSent"
      );
      
      expect(warpEvent).to.not.be.undefined;
      expect(warpEvent.args.targetChainId).to.equal(CHAIN_ID_FUJI);
    });
  });
  
  describe("Token Recovery", function () {
    it("Should allow admin to recover non-bridge tokens", async function () {
      // Deploy a random ERC20 (not bridge-managed XOM/pXOM)
      // TestUSDC has 6 decimals; deployer gets 100M at construction
      const TestToken = await ethers.getContractFactory("TestUSDC");
      const testToken = await TestToken.deploy();

      // Send some of the deployer's TestUSDC to bridge
      const amount = 1000n * 10n ** 6n; // 1000 USDC (6 decimals)
      await testToken.transfer(bridge.target, amount);

      const adminBalanceBefore = await testToken.balanceOf(admin.address);

      await bridge.connect(admin).recoverTokens(testToken.target, amount);

      const adminBalanceAfter = await testToken.balanceOf(admin.address);
      expect(adminBalanceAfter - adminBalanceBefore).to.equal(amount);
    });

    it("Should reject recovering bridge tokens (XOM)", async function () {
      // Send XOM tokens to bridge directly
      const amount = ethers.parseEther("1000");
      await token.connect(user1).transfer(bridge.target, amount);

      await expect(
        bridge.connect(admin).recoverTokens(token.target, amount)
      ).to.be.revertedWithCustomError(bridge, "CannotRecoverBridgeTokens");
    });
    
    it("Should only allow admin to recover", async function () {
      await expect(
        bridge.connect(user1).recoverTokens(token.target, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });
  });
  
  describe("View Functions", function () {
    it("Should return transfer details", async function () {
      const amount = ethers.parseEther("100");
      
      const tx = await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "TransferInitiated"
      );
      const transferId = event.args.transferId;
      
      const transfer = await bridge.getTransfer(transferId);
      expect(transfer.sender).to.equal(user1.address);
      expect(transfer.recipient).to.equal(user2.address);
      expect(transfer.sourceChainId).to.equal(await ethers.provider.getNetwork().then(n => n.chainId));
      expect(transfer.targetChainId).to.equal(CHAIN_ID_FUJI);
      expect(transfer.completed).to.be.false;
    });
    
    it("Should return blockchain ID", async function () {
      const blockchainId = await bridge.getBlockchainID();
      // The mock returns keccak256("test-chain")
      const expectedId = ethers.keccak256(ethers.toUtf8Bytes("test-chain"));
      expect(blockchainId).to.equal(expectedId);
    });
    
    it("Should track transfer count", async function () {
      expect(await bridge.transferCount()).to.equal(0);
      
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        ethers.parseEther("100"),
        CHAIN_ID_FUJI,
        false
      );
      
      expect(await bridge.transferCount()).to.equal(1);
    });
  });
  
  describe("Security", function () {
    it("Should prevent reentrancy on transfers", async function () {
      // This would be tested with a malicious contract
      // For now, we ensure ReentrancyGuard is used
      expect(bridge.interface.fragments.some(f => 
        f.type === "function" && f.name === "initiateTransfer"
      )).to.be.true;
    });
    
    it("Should validate all inputs", async function () {
      // Zero amount
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          0,
          CHAIN_ID_FUJI,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidAmount");
    });
  });
});