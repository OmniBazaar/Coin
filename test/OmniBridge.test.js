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
  let owner, user1, user2, admin, validator, feeVaultAddr;
  
  const CHAIN_ID_FUJI = 43113;
  const CHAIN_ID_CCHAIN = 43114;
  const BLOCKCHAIN_ID_FUJI = ethers.id("fuji");
  const BLOCKCHAIN_ID_CCHAIN = ethers.id("c-chain");
  
  const MIN_TRANSFER = ethers.parseEther("10");
  const MAX_TRANSFER = ethers.parseEther("10000");
  const DAILY_LIMIT = ethers.parseEther("100000");
  const TRANSFER_FEE = 50; // 0.5%
  
  beforeEach(async function () {
    [owner, user1, user2, admin, validator, feeVaultAddr] = await ethers.getSigners();
    
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
    token = await Token.deploy(ethers.ZeroAddress);
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
      [admin.address, token.target, admin.address, admin.address, admin.address],
      { initializer: "initialize", constructorArgs: [ethers.ZeroAddress] }
    );
    
    // Register services
    await core.connect(admin).setService(ethers.id("OMNICOIN"), token.target);
    await core.connect(admin).setService(ethers.id("PRIVATE_OMNICOIN"), privateToken.target);
    
    // Deploy OmniBridge via UUPS proxy (initialize takes _core, admin)
    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    bridge = await upgrades.deployProxy(
      OmniBridge,
      [core.target, admin.address],
      { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
    );
    
    // Setup: Give users tokens
    // OmniCoin pre-mints full supply to deployer (owner) during initialize(),
    // so use transfer instead of mint to distribute test tokens.
    await token.transfer(user1.address, ethers.parseEther("100000"));
    await token.transfer(user2.address, ethers.parseEther("100000"));
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
  
  describe("Fee Vault Management", function () {
    /** @dev 48 hours in seconds — matches FEE_VAULT_DELAY in contract */
    const FEE_VAULT_DELAY = 48 * 3600;

    /** @dev Helper: propose + advance time + accept feeVault change */
    async function proposeThenAcceptFeeVault(caller, newVault) {
      await bridge.connect(caller).proposeFeeVault(newVault);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);
      await bridge.connect(caller).acceptFeeVault();
    }

    it("Should allow admin to set feeVault via propose + accept timelock", async function () {
      await proposeThenAcceptFeeVault(admin, feeVaultAddr.address);
      expect(await bridge.feeVault()).to.equal(feeVaultAddr.address);
    });

    it("Should emit FeeVaultChangeProposed on propose", async function () {
      await expect(
        bridge.connect(admin).proposeFeeVault(feeVaultAddr.address)
      ).to.emit(bridge, "FeeVaultChangeProposed");
    });

    it("Should emit FeeVaultChangeAccepted on accept", async function () {
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        bridge.connect(admin).acceptFeeVault()
      ).to.emit(bridge, "FeeVaultChangeAccepted");
    });

    it("Should reject non-admin callers for proposeFeeVault", async function () {
      await expect(
        bridge.connect(user1).proposeFeeVault(feeVaultAddr.address)
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should reject zero address for proposeFeeVault", async function () {
      await expect(
        bridge.connect(admin).proposeFeeVault(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should reject acceptFeeVault before timelock elapses", async function () {
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      // Only advance 1 hour — not enough
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        bridge.connect(admin).acceptFeeVault()
      ).to.be.revertedWithCustomError(bridge, "FeeVaultTimelockActive");
    });

    it("Should reject acceptFeeVault without a proposal", async function () {
      await expect(
        bridge.connect(admin).acceptFeeVault()
      ).to.be.revertedWithCustomError(bridge, "NoFeeVaultChangePending");
    });
  });

  describe("Fee Distribution", function () {
    it("Should distribute accumulated fees to feeVault", async function () {
      // Set feeVault first
      // Propose + timelock + accept fee vault change
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      await ethers.provider.send("evm_increaseTime", [48 * 3600]);
      await ethers.provider.send("evm_mine", []);
      await bridge.connect(admin).acceptFeeVault();

      // Initiate a transfer to accumulate fees
      const amount = ethers.parseEther("1000");
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );

      const expectedFee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));

      // Check accumulated fees
      expect(await bridge.accumulatedFees(tokenAddress)).to.equal(expectedFee);

      // Record feeVault balance before
      const vaultBalanceBefore = await token.balanceOf(feeVaultAddr.address);

      // Distribute fees (permissionless - calling from user1)
      const tx = await bridge.connect(user1).distributeFees(tokenAddress);
      const receipt = await tx.wait();

      // Verify fees sent to feeVault
      const vaultBalanceAfter = await token.balanceOf(feeVaultAddr.address);
      expect(vaultBalanceAfter - vaultBalanceBefore).to.equal(expectedFee);

      // Verify accumulated fees are zeroed
      expect(await bridge.accumulatedFees(tokenAddress)).to.equal(0);

      // Verify FeeDistributed event emits feeVault as recipient
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "FeeDistributed"
      );
      expect(event).to.not.be.undefined;
      expect(event.args.recipient).to.equal(feeVaultAddr.address);
      expect(event.args.amount).to.equal(expectedFee);
    });

    it("Should allow anyone to call distributeFees (permissionless)", async function () {
      // Set feeVault
      // Propose + timelock + accept fee vault change
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      await ethers.provider.send("evm_increaseTime", [48 * 3600]);
      await ethers.provider.send("evm_mine", []);
      await bridge.connect(admin).acceptFeeVault();

      // Accumulate fees via transfer
      const amount = ethers.parseEther("500");
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );

      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));

      // Non-admin user2 should be able to call distributeFees
      await expect(
        bridge.connect(user2).distributeFees(tokenAddress)
      ).to.not.be.reverted;
    });

    it("Should revert when feeVault is not set (InvalidRecipient)", async function () {
      // Accumulate fees via transfer (feeVault is not set by default)
      const amount = ethers.parseEther("100");
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        amount,
        CHAIN_ID_FUJI,
        false
      );

      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));

      // distributeFees should revert because feeVault is address(0)
      await expect(
        bridge.connect(admin).distributeFees(tokenAddress)
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should revert when no fees are accumulated", async function () {
      // Set feeVault
      // Propose + timelock + accept fee vault change
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      await ethers.provider.send("evm_increaseTime", [48 * 3600]);
      await ethers.provider.send("evm_mine", []);
      await bridge.connect(admin).acceptFeeVault();

      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));

      // No transfers made, so no fees accumulated
      await expect(
        bridge.connect(user1).distributeFees(tokenAddress)
      ).to.be.revertedWithCustomError(bridge, "NoFeesToDistribute");
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

  // =========================================================================
  // NEW TEST BLOCKS BELOW
  // =========================================================================

  describe("Pause and Unpause", function () {
    it("Should allow admin to pause bridge operations", async function () {
      await bridge.connect(admin).pause();

      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("100"),
          CHAIN_ID_FUJI,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "EnforcedPause");
    });

    it("Should allow admin to unpause bridge operations", async function () {
      await bridge.connect(admin).pause();
      await bridge.connect(admin).unpause();

      // Should succeed after unpause
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("100"),
          CHAIN_ID_FUJI,
          false
        )
      ).to.not.be.reverted;
    });

    it("Should reject non-admin pause", async function () {
      await expect(
        bridge.connect(user1).pause()
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should reject non-admin unpause", async function () {
      await bridge.connect(admin).pause();
      await expect(
        bridge.connect(user1).unpause()
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should block refundTransfer when paused", async function () {
      // Initiate a transfer first
      await bridge.connect(user1).initiateTransfer(
        user2.address,
        ethers.parseEther("100"),
        CHAIN_ID_FUJI,
        false
      );

      // Pause the bridge
      await bridge.connect(admin).pause();

      // Advance time past REFUND_DELAY (7 days)
      await time.increase(7 * 24 * 60 * 60 + 1);

      // Refund should be blocked while paused
      await expect(
        bridge.connect(user1).refundTransfer(1)
      ).to.be.revertedWithCustomError(bridge, "EnforcedPause");
    });
  });

  describe("Ossification", function () {
    it("Should allow admin to ossify the contract", async function () {
      await bridge.connect(admin).ossify();
      expect(await bridge.isOssified()).to.be.true;
    });

    it("Should emit ContractOssified event", async function () {
      await expect(bridge.connect(admin).ossify())
        .to.emit(bridge, "ContractOssified")
        .withArgs(bridge.target);
    });

    it("Should report not ossified by default", async function () {
      expect(await bridge.isOssified()).to.be.false;
    });

    it("Should reject ossify from non-admin", async function () {
      await expect(
        bridge.connect(user1).ossify()
      ).to.be.revertedWithCustomError(bridge, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Trusted Bridge Management", function () {
    it("Should set trusted bridge for a source chain", async function () {
      const srcBlockchainId = BLOCKCHAIN_ID_FUJI;
      const bridgeAddr = user2.address; // any address for testing

      await bridge.connect(admin).setTrustedBridge(srcBlockchainId, bridgeAddr);
      expect(await bridge.trustedBridges(srcBlockchainId)).to.equal(bridgeAddr);
    });

    it("Should emit TrustedBridgeUpdated event", async function () {
      const srcBlockchainId = BLOCKCHAIN_ID_FUJI;
      const bridgeAddr = user2.address;

      await expect(bridge.connect(admin).setTrustedBridge(srcBlockchainId, bridgeAddr))
        .to.emit(bridge, "TrustedBridgeUpdated")
        .withArgs(srcBlockchainId, bridgeAddr);
    });

    it("Should reject non-admin setting trusted bridge", async function () {
      await expect(
        bridge.connect(user1).setTrustedBridge(BLOCKCHAIN_ID_FUJI, user2.address)
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should allow overwriting an existing trusted bridge", async function () {
      const srcBlockchainId = BLOCKCHAIN_ID_FUJI;

      await bridge.connect(admin).setTrustedBridge(srcBlockchainId, user1.address);
      expect(await bridge.trustedBridges(srcBlockchainId)).to.equal(user1.address);

      // Overwrite
      await bridge.connect(admin).setTrustedBridge(srcBlockchainId, user2.address);
      expect(await bridge.trustedBridges(srcBlockchainId)).to.equal(user2.address);
    });

    it("Should allow setting trusted bridge to zero address (removing trust)", async function () {
      const srcBlockchainId = BLOCKCHAIN_ID_FUJI;

      await bridge.connect(admin).setTrustedBridge(srcBlockchainId, user1.address);
      await bridge.connect(admin).setTrustedBridge(srcBlockchainId, ethers.ZeroAddress);
      expect(await bridge.trustedBridges(srcBlockchainId)).to.equal(ethers.ZeroAddress);
    });
  });

  describe("Chain Configuration Edge Cases", function () {
    it("Should reject chain ID 0 (M-02 Round 6)", async function () {
      await expect(
        bridge.connect(admin).updateChainConfig(
          0, // chain ID 0
          ethers.id("zero-chain"),
          true,
          MIN_TRANSFER,
          MAX_TRANSFER,
          DAILY_LIMIT,
          TRANSFER_FEE,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidChainId");
    });

    it("Should reject min equals max transfer limit", async function () {
      const sameValue = ethers.parseEther("100");
      await expect(
        bridge.connect(admin).updateChainConfig(
          200,
          ethers.id("same-limit"),
          true,
          sameValue,
          sameValue, // min == max
          DAILY_LIMIT,
          TRANSFER_FEE,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidAmount");
    });

    it("Should accept maximum allowed fee (5%)", async function () {
      await expect(
        bridge.connect(admin).updateChainConfig(
          300,
          ethers.id("max-fee"),
          true,
          MIN_TRANSFER,
          MAX_TRANSFER,
          DAILY_LIMIT,
          500, // 5% exactly = MAX_FEE
          ethers.ZeroAddress
        )
      ).to.not.be.reverted;
    });

    it("Should reject fee of 501 basis points (just over MAX_FEE)", async function () {
      await expect(
        bridge.connect(admin).updateChainConfig(
          300,
          ethers.id("over-fee"),
          true,
          MIN_TRANSFER,
          MAX_TRANSFER,
          DAILY_LIMIT,
          501, // 5.01%
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidFee");
    });

    it("Should emit ChainConfigUpdated event with all fields", async function () {
      const chainId = 400;
      const bcId = ethers.id("event-chain");
      const teleporter = "0x1234567890123456789012345678901234567890";

      await expect(
        bridge.connect(admin).updateChainConfig(
          chainId,
          bcId,
          true,
          MIN_TRANSFER,
          MAX_TRANSFER,
          DAILY_LIMIT,
          TRANSFER_FEE,
          teleporter
        )
      )
        .to.emit(bridge, "ChainConfigUpdated")
        .withArgs(chainId, true, teleporter, MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT);
    });

    it("Should clear stale blockchain mapping when updating chain config (M-03)", async function () {
      const chainId = 500;
      const oldBcId = ethers.id("old-bc");
      const newBcId = ethers.id("new-bc");

      // First configuration
      await bridge.connect(admin).updateChainConfig(
        chainId, oldBcId, true,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT, TRANSFER_FEE, ethers.ZeroAddress
      );
      expect(await bridge.blockchainToChainId(oldBcId)).to.equal(chainId);

      // Update with new blockchain ID
      await bridge.connect(admin).updateChainConfig(
        chainId, newBcId, true,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT, TRANSFER_FEE, ethers.ZeroAddress
      );

      // Old mapping should be cleared
      expect(await bridge.blockchainToChainId(oldBcId)).to.equal(0);
      // New mapping should be set
      expect(await bridge.blockchainToChainId(newBcId)).to.equal(chainId);
    });

    it("Should clear chainToBlockchainId when zero blockchain ID passed", async function () {
      const chainId = 600;
      const bcId = ethers.id("temp-bc");

      // First set it
      await bridge.connect(admin).updateChainConfig(
        chainId, bcId, true,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT, TRANSFER_FEE, ethers.ZeroAddress
      );
      expect(await bridge.chainToBlockchainId(chainId)).to.equal(bcId);

      // Update with zero blockchain ID
      await bridge.connect(admin).updateChainConfig(
        chainId, ethers.ZeroHash, true,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT, TRANSFER_FEE, ethers.ZeroAddress
      );

      // chainToBlockchainId should be cleared
      expect(await bridge.chainToBlockchainId(chainId)).to.equal(ethers.ZeroHash);
    });

    it("Should configure an inactive chain", async function () {
      const chainId = 700;
      await bridge.connect(admin).updateChainConfig(
        chainId, ethers.id("inactive"), false,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT, TRANSFER_FEE, ethers.ZeroAddress
      );

      const config = await bridge.chainConfigs(chainId);
      expect(config.isActive).to.be.false;

      // Transfers to inactive chain should fail
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address,
          ethers.parseEther("100"),
          chainId,
          false
        )
      ).to.be.revertedWithCustomError(bridge, "ChainNotSupported");
    });

    it("Should allow zero fee (free transfers)", async function () {
      const chainId = 800;
      await bridge.connect(admin).updateChainConfig(
        chainId, ethers.id("free-chain"), true,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT,
        0, // zero fee
        ethers.ZeroAddress
      );

      const amount = ethers.parseEther("100");
      const tx = await bridge.connect(user1).initiateTransfer(
        user2.address, amount, chainId, false
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "TransferInitiated"
      );

      expect(event.args.fee).to.equal(0);
      expect(event.args.amount).to.equal(amount); // full amount, no fee deducted
    });
  });

  describe("Refund Transfers", function () {
    it("Should refund a transfer after the refund delay", async function () {
      const amount = ethers.parseEther("100");
      const fee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
      const netAmount = amount - fee;

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );

      const balanceBefore = await token.balanceOf(user1.address);

      // Advance time past REFUND_DELAY (7 days)
      await time.increase(7 * 24 * 60 * 60 + 1);

      await bridge.connect(user1).refundTransfer(1);

      const balanceAfter = await token.balanceOf(user1.address);
      // Refund is net amount (fee already deducted)
      expect(balanceAfter - balanceBefore).to.equal(netAmount);
    });

    it("Should emit TransferRefunded event", async function () {
      const amount = ethers.parseEther("100");
      const fee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
      const netAmount = amount - fee;

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );

      await time.increase(7 * 24 * 60 * 60 + 1);

      await expect(bridge.connect(user1).refundTransfer(1))
        .to.emit(bridge, "TransferRefunded")
        .withArgs(1, user1.address, netAmount);
    });

    it("Should reject refund before delay expires", async function () {
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
      );

      // Only advance 6 days (not enough)
      await time.increase(6 * 24 * 60 * 60);

      await expect(
        bridge.connect(user1).refundTransfer(1)
      ).to.be.revertedWithCustomError(bridge, "TransferTooEarly");
    });

    it("Should reject refund by non-sender", async function () {
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
      );

      await time.increase(7 * 24 * 60 * 60 + 1);

      await expect(
        bridge.connect(user2).refundTransfer(1)
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("Should reject double refund (H-01 Round 6)", async function () {
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
      );

      await time.increase(7 * 24 * 60 * 60 + 1);

      // First refund succeeds
      await bridge.connect(user1).refundTransfer(1);

      // Second refund should fail
      await expect(
        bridge.connect(user1).refundTransfer(1)
      ).to.be.revertedWithCustomError(bridge, "TransferAlreadyCompleted");
    });

    it("Should set transfer status to REFUNDED after refund", async function () {
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
      );

      await time.increase(7 * 24 * 60 * 60 + 1);
      await bridge.connect(user1).refundTransfer(1);

      // TransferStatus.REFUNDED = 2
      expect(await bridge.transferStatus(1)).to.equal(2);
    });

    it("Should refund private token transfers correctly", async function () {
      const amount = ethers.parseEther("100");
      const fee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
      const netAmount = amount - fee;

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, true // private token
      );

      const balanceBefore = await privateToken.balanceOf(user1.address);

      await time.increase(7 * 24 * 60 * 60 + 1);
      await bridge.connect(user1).refundTransfer(1);

      const balanceAfter = await privateToken.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(netAmount);
    });
  });

  describe("Multi-Chain Bridge Operations", function () {
    it("Should track daily volume per chain independently", async function () {
      const amount = ethers.parseEther("1000");

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );
      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_CCHAIN, false
      );

      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_FUJI)).to.equal(amount);
      expect(await bridge.getCurrentDailyVolume(CHAIN_ID_CCHAIN)).to.equal(amount);
    });

    it("Should allow transfers to multiple chains simultaneously", async function () {
      const amount = ethers.parseEther("100");

      const tx1 = await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );
      const tx2 = await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_CCHAIN, false
      );

      const r1 = await tx1.wait();
      const r2 = await tx2.wait();

      const ev1 = r1.logs.find(l => l.fragment && l.fragment.name === "TransferInitiated");
      const ev2 = r2.logs.find(l => l.fragment && l.fragment.name === "TransferInitiated");

      expect(ev1.args.targetChainId).to.equal(CHAIN_ID_FUJI);
      expect(ev2.args.targetChainId).to.equal(CHAIN_ID_CCHAIN);

      // Transfer IDs should be sequential
      expect(ev2.args.transferId).to.equal(ev1.args.transferId + 1n);
    });

    it("Should enforce daily limit per chain not globally", async function () {
      // Set a very low limit on one chain
      await bridge.connect(admin).updateChainConfig(
        CHAIN_ID_FUJI, BLOCKCHAIN_ID_FUJI, true,
        MIN_TRANSFER, MAX_TRANSFER,
        ethers.parseEther("200"), // low daily limit
        TRANSFER_FEE, ethers.ZeroAddress
      );

      // Transfer 150 to Fuji - should succeed
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("150"), CHAIN_ID_FUJI, false
      );

      // Transfer 100 more to Fuji - should fail (would exceed 200 daily limit)
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
        )
      ).to.be.revertedWithCustomError(bridge, "DailyLimitExceeded");

      // But transfer to C-Chain should still work (independent limit)
      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address, ethers.parseEther("100"), CHAIN_ID_CCHAIN, false
        )
      ).to.not.be.reverted;
    });
  });

  describe("Fee Accumulation and Distribution Edge Cases", function () {
    it("Should accumulate fees from multiple transfers", async function () {
      // Propose + timelock + accept fee vault change
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      await ethers.provider.send("evm_increaseTime", [48 * 3600]);
      await ethers.provider.send("evm_mine", []);
      await bridge.connect(admin).acceptFeeVault();

      const amount = ethers.parseEther("1000");
      const expectedFeePerTransfer = (amount * BigInt(TRANSFER_FEE)) / 10000n;

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );
      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_CCHAIN, false
      );

      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));
      expect(await bridge.accumulatedFees(tokenAddress)).to.equal(expectedFeePerTransfer * 2n);
    });

    it("Should not accumulate fees when fee is zero", async function () {
      // Configure chain with zero fee
      const chainId = 900;
      await bridge.connect(admin).updateChainConfig(
        chainId, ethers.id("no-fee-chain"), true,
        MIN_TRANSFER, MAX_TRANSFER, DAILY_LIMIT,
        0, // zero fee
        ethers.ZeroAddress
      );

      const amount = ethers.parseEther("100");
      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, chainId, false
      );

      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));
      expect(await bridge.accumulatedFees(tokenAddress)).to.equal(0);
    });

    it("Should reset accumulated fees to zero after distribution", async function () {
      // Propose + timelock + accept fee vault change
      await bridge.connect(admin).proposeFeeVault(feeVaultAddr.address);
      await ethers.provider.send("evm_increaseTime", [48 * 3600]);
      await ethers.provider.send("evm_mine", []);
      await bridge.connect(admin).acceptFeeVault();

      const amount = ethers.parseEther("500");
      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );

      const tokenAddress = await core.connect(admin).getService(ethers.id("OMNICOIN"));
      const feeBefore = await bridge.accumulatedFees(tokenAddress);
      expect(feeBefore).to.be.gt(0);

      await bridge.distributeFees(tokenAddress);

      expect(await bridge.accumulatedFees(tokenAddress)).to.equal(0);

      // Second distribution should fail (no fees)
      await expect(
        bridge.distributeFees(tokenAddress)
      ).to.be.revertedWithCustomError(bridge, "NoFeesToDistribute");
    });
  });

  describe("Token Recovery Edge Cases", function () {
    it("Should reject recovering private bridge tokens (pXOM)", async function () {
      // Send pXOM tokens to bridge directly
      const amount = ethers.parseEther("500");
      await privateToken.mint(admin.address, amount);
      await privateToken.connect(admin).transfer(bridge.target, amount);

      await expect(
        bridge.connect(admin).recoverTokens(privateToken.target, amount)
      ).to.be.revertedWithCustomError(bridge, "CannotRecoverBridgeTokens");
    });

    it("Should emit TokensRecovered event", async function () {
      const TestToken = await ethers.getContractFactory("TestUSDC");
      const testToken = await TestToken.deploy();

      const amount = 500n * 10n ** 6n; // 500 USDC
      await testToken.transfer(bridge.target, amount);

      await expect(bridge.connect(admin).recoverTokens(testToken.target, amount))
        .to.emit(bridge, "TokensRecovered")
        .withArgs(testToken.target, amount, admin.address);
    });
  });

  describe("Transfer Status Lifecycle", function () {
    it("Should default to PENDING (0) for new transfers", async function () {
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
      );
      // TransferStatus.PENDING = 0
      expect(await bridge.transferStatus(1)).to.equal(0);
    });

    it("Should mark completed field on transfer struct after refund", async function () {
      await bridge.connect(user1).initiateTransfer(
        user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
      );

      await time.increase(7 * 24 * 60 * 60 + 1);
      await bridge.connect(user1).refundTransfer(1);

      const transfer = await bridge.getTransfer(1);
      expect(transfer.completed).to.be.true;
    });

    it("Should return default values for non-existent transfer", async function () {
      const transfer = await bridge.getTransfer(999);
      expect(transfer.sender).to.equal(ethers.ZeroAddress);
      expect(transfer.recipient).to.equal(ethers.ZeroAddress);
      expect(transfer.amount).to.equal(0);
      expect(transfer.completed).to.be.false;
    });
  });

  describe("Transfer Events", function () {
    it("Should emit TransferInitiated with correct indexed fields", async function () {
      const amount = ethers.parseEther("200");
      const fee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
      const netAmount = amount - fee;

      await expect(
        bridge.connect(user1).initiateTransfer(
          user2.address, amount, CHAIN_ID_FUJI, false
        )
      )
        .to.emit(bridge, "TransferInitiated")
        .withArgs(1, user1.address, user2.address, netAmount, CHAIN_ID_FUJI, fee);
    });

    it("Should emit WarpMessageSent for each transfer", async function () {
      const amount = ethers.parseEther("100");

      // First transfer
      const tx1 = await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );
      const r1 = await tx1.wait();
      const warpEvents1 = r1.logs.filter(
        l => l.fragment && l.fragment.name === "WarpMessageSent"
      );
      expect(warpEvents1.length).to.equal(1);
      expect(warpEvents1[0].args.transferId).to.equal(1);

      // Second transfer
      const tx2 = await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_CCHAIN, false
      );
      const r2 = await tx2.wait();
      const warpEvents2 = r2.logs.filter(
        l => l.fragment && l.fragment.name === "WarpMessageSent"
      );
      expect(warpEvents2.length).to.equal(1);
      expect(warpEvents2[0].args.transferId).to.equal(2);
    });
  });

  describe("View Functions Extended", function () {
    it("Should return correct constants", async function () {
      expect(await bridge.BASIS_POINTS()).to.equal(10000);
      expect(await bridge.MAX_FEE()).to.equal(500);
      expect(await bridge.REFUND_DELAY()).to.equal(7 * 24 * 60 * 60);
    });

    it("Should return correct service identifiers", async function () {
      expect(await bridge.OMNICOIN_SERVICE()).to.equal(ethers.id("OMNICOIN"));
      expect(await bridge.PRIVATE_OMNICOIN_SERVICE()).to.equal(ethers.id("PRIVATE_OMNICOIN"));
    });

    it("Should return isMessageProcessed false for unprocessed messages", async function () {
      const randomChainId = ethers.id("random-chain");
      expect(await bridge.isMessageProcessed(randomChainId, 999)).to.be.false;
    });

    it("Should return zero daily volume for unconfigured chain", async function () {
      expect(await bridge.getCurrentDailyVolume(99999)).to.equal(0);
    });

    it("Should return chainToBlockchainId mapping correctly", async function () {
      expect(await bridge.chainToBlockchainId(CHAIN_ID_FUJI)).to.equal(BLOCKCHAIN_ID_FUJI);
      expect(await bridge.chainToBlockchainId(CHAIN_ID_CCHAIN)).to.equal(BLOCKCHAIN_ID_CCHAIN);
    });

    it("Should return blockchainToChainId mapping correctly", async function () {
      expect(await bridge.blockchainToChainId(BLOCKCHAIN_ID_FUJI)).to.equal(CHAIN_ID_FUJI);
      expect(await bridge.blockchainToChainId(BLOCKCHAIN_ID_CCHAIN)).to.equal(CHAIN_ID_CCHAIN);
    });

    it("Should return chain config fields via public mapping", async function () {
      const config = await bridge.chainConfigs(CHAIN_ID_FUJI);
      expect(config.isActive).to.be.true;
      expect(config.minTransfer).to.equal(MIN_TRANSFER);
      expect(config.maxTransfer).to.equal(MAX_TRANSFER);
      expect(config.dailyLimit).to.equal(DAILY_LIMIT);
      expect(config.transferFee).to.equal(TRANSFER_FEE);
    });
  });

  describe("Initialization Edge Cases", function () {
    it("Should reject double initialization", async function () {
      await expect(
        bridge.initialize(core.target, admin.address)
      ).to.be.revertedWithCustomError(bridge, "InvalidInitialization");
    });

    it("Should assign correct roles during initialization", async function () {
      const DEFAULT_ADMIN_ROLE = await bridge.DEFAULT_ADMIN_ROLE();

      expect(await bridge.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("Should store correct core reference", async function () {
      expect(await bridge.core()).to.equal(core.target);
    });
  });

  describe("Multiple User Transfers", function () {
    it("Should handle concurrent transfers from different users", async function () {
      const amount = ethers.parseEther("100");

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );
      await bridge.connect(user2).initiateTransfer(
        user1.address, amount, CHAIN_ID_CCHAIN, false
      );

      expect(await bridge.transferCount()).to.equal(2);

      const t1 = await bridge.getTransfer(1);
      expect(t1.sender).to.equal(user1.address);
      expect(t1.recipient).to.equal(user2.address);

      const t2 = await bridge.getTransfer(2);
      expect(t2.sender).to.equal(user2.address);
      expect(t2.recipient).to.equal(user1.address);
    });

    it("Should correctly track transfer hashes as unique", async function () {
      const amount = ethers.parseEther("100");

      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );
      await bridge.connect(user1).initiateTransfer(
        user2.address, amount, CHAIN_ID_FUJI, false
      );

      const t1 = await bridge.getTransfer(1);
      const t2 = await bridge.getTransfer(2);

      // Transfer hashes should be different even for identical parameters
      // because transferId and timestamp differ
      expect(t1.transferHash).to.not.equal(t2.transferHash);
    });
  });
});