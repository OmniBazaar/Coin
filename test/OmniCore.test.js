const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCore", function () {
  let core;
  let token;
  let owner, validator1, validator2, staker1, staker2;
  
  const STAKE_AMOUNT = ethers.parseEther("1000");
  const MIN_STAKE = ethers.parseEther("100");
  
  beforeEach(async function () {
    [owner, validator1, validator2, staker1, staker2] = await ethers.getSigners();
    
    // Deploy OmniCoin token
    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy();
    await token.initialize();
    
    // Deploy OmniCore with all required constructor arguments
    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await OmniCore.deploy(owner.address, token.target, owner.address, owner.address);
    
    // Grant MINTER_ROLE to core contract so it can mint rewards
    await token.grantRole(await token.MINTER_ROLE(), core.target);
    
    // Setup: Give users tokens
    await token.mint(validator1.address, ethers.parseEther("10000"));
    await token.mint(validator2.address, ethers.parseEther("10000"));
    await token.mint(staker1.address, ethers.parseEther("10000"));
    await token.mint(staker2.address, ethers.parseEther("10000"));
    
    // Mint some tokens to core for rewards distribution
    await token.mint(core.target, ethers.parseEther("100000"));
    
    // Approve core contract
    await token.connect(validator1).approve(core.target, ethers.parseEther("10000"));
    await token.connect(validator2).approve(core.target, ethers.parseEther("10000"));
    await token.connect(staker1).approve(core.target, ethers.parseEther("10000"));
    await token.connect(staker2).approve(core.target, ethers.parseEther("10000"));
  });
  
  describe("Service Registry", function () {
    it("Should register services", async function () {
      const serviceId = ethers.id("marketplace");
      const serviceAddress = "0x1234567890123456789012345678901234567890";
      
      await core.connect(owner).setService(serviceId, serviceAddress);
      
      expect(await core.services(serviceId)).to.equal(serviceAddress);
    });
    
    it("Should update service addresses", async function () {
      const serviceId = ethers.id("bridge");
      const oldAddress = "0x1234567890123456789012345678901234567890";
      const newAddress = "0x0987654321098765432109876543210987654321";
      
      await core.connect(owner).setService(serviceId, oldAddress);
      await core.connect(owner).setService(serviceId, newAddress);
      
      expect(await core.services(serviceId)).to.equal(newAddress);
    });
    
    it("Should only allow owner to register services", async function () {
      const serviceId = ethers.id("test");
      const serviceAddress = "0x1234567890123456789012345678901234567890";
      
      await expect(
        core.connect(validator1).setService(serviceId, serviceAddress)
      ).to.be.revertedWithCustomError(core, "AccessControlUnauthorizedAccount");
    });
    
    it("Should emit ServiceUpdated event", async function () {
      const serviceId = ethers.id("escrow");
      const serviceAddress = "0x1234567890123456789012345678901234567890";
      
      const tx = await core.connect(owner).setService(serviceId, serviceAddress);
      const block = await ethers.provider.getBlock(tx.blockNumber);
      
      await expect(tx)
        .to.emit(core, "ServiceUpdated")
        .withArgs(serviceId, serviceAddress, block.timestamp);
    });
  });
  
  describe("Validator Management", function () {
    it("Should register validators", async function () {
      await core.connect(owner).setValidator(validator1.address, true);
      
      expect(await core.validators(validator1.address)).to.be.true;
    });
    
    it("Should remove validators", async function () {
      await core.connect(owner).setValidator(validator1.address, true);
      await core.connect(owner).setValidator(validator1.address, false);
      
      expect(await core.validators(validator1.address)).to.be.false;
    });
    
    it("Should emit validator events", async function () {
      const tx1 = await core.connect(owner).setValidator(validator1.address, true);
      const block1 = await ethers.provider.getBlock(tx1.blockNumber);
      
      await expect(tx1)
        .to.emit(core, "ValidatorUpdated")
        .withArgs(validator1.address, true, block1.timestamp);
        
      const tx2 = await core.connect(owner).setValidator(validator1.address, false);
      const block2 = await ethers.provider.getBlock(tx2.blockNumber);
      
      await expect(tx2)
        .to.emit(core, "ValidatorUpdated")
        .withArgs(validator1.address, false, block2.timestamp);
    });
  });
  
  describe("Master Merkle Root", function () {
    it("Should update merkle root", async function () {
      const newRoot = ethers.randomBytes(32);
      
      // Register validator first
      await core.connect(owner).setValidator(validator1.address, true);
      
      // Grant AVALANCHE_VALIDATOR_ROLE to validator1
      const AVALANCHE_VALIDATOR_ROLE = await core.AVALANCHE_VALIDATOR_ROLE();
      await core.connect(owner).grantRole(AVALANCHE_VALIDATOR_ROLE, validator1.address);
      
      await core.connect(validator1).updateMasterRoot(newRoot, 1);
      
      expect(await core.masterRoot()).to.equal(ethers.hexlify(newRoot));
      expect(await core.lastRootUpdate()).to.equal(1);
    });
    
    it("Should only allow validators to update root", async function () {
      const newRoot = ethers.randomBytes(32);
      
      await expect(
        core.connect(staker1).updateMasterRoot(newRoot, 1)
      ).to.be.revertedWithCustomError(core, "AccessControlUnauthorizedAccount");
    });
    
    it("Should emit MasterRootUpdated event", async function () {
      const newRoot = ethers.randomBytes(32);
      await core.connect(owner).setValidator(validator1.address, true);
      
      // Grant AVALANCHE_VALIDATOR_ROLE
      const AVALANCHE_VALIDATOR_ROLE = await core.AVALANCHE_VALIDATOR_ROLE();
      await core.connect(owner).grantRole(AVALANCHE_VALIDATOR_ROLE, validator1.address);
      
      const tx = await core.connect(validator1).updateMasterRoot(newRoot, 1);
      const block = await ethers.provider.getBlock(tx.blockNumber);
      
      await expect(tx)
        .to.emit(core, "MasterRootUpdated")
        .withArgs(ethers.hexlify(newRoot), 1, block.timestamp);
    });
  });
  
  describe("Minimal Staking", function () {
    it("Should allow staking", async function () {
      const tier = 1; // Silver tier
      const duration = 30 * 24 * 60 * 60; // 30 days
      
      await core.connect(staker1).stake(STAKE_AMOUNT, tier, duration);
      
      const position = await core.stakes(staker1.address);
      expect(position.amount).to.equal(STAKE_AMOUNT);
      expect(position.tier).to.equal(tier);
      expect(position.duration).to.equal(duration);
      expect(position.active).to.be.true;
    });
    
    it("Should transfer tokens on stake", async function () {
      const balanceBefore = await token.balanceOf(staker1.address);
      const coreBalanceBefore = await token.balanceOf(core.target);
      
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60);
      
      const balanceAfter = await token.balanceOf(staker1.address);
      const coreBalanceAfter = await token.balanceOf(core.target);
      
      expect(balanceBefore - balanceAfter).to.equal(STAKE_AMOUNT);
      expect(coreBalanceAfter - coreBalanceBefore).to.equal(STAKE_AMOUNT);
    });
    
    it("Should enforce non-zero stake amount", async function () {
      await expect(
        core.connect(staker1).stake(0, 1, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });
    
    it("Should prevent staking with existing position", async function () {
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60);
      
      await expect(
        core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });
  });
  
  describe("Merkle Proof Unlocking", function () {
    beforeEach(async function () {
      // Stake first
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60);
      
      // Register validator and grant role
      await core.connect(owner).setValidator(validator1.address, true);
      const AVALANCHE_VALIDATOR_ROLE = await core.AVALANCHE_VALIDATOR_ROLE();
      await core.connect(owner).grantRole(AVALANCHE_VALIDATOR_ROLE, validator1.address);
    });
    
    it("Should unlock with valid merkle proof", async function () {
      // In real implementation, validator would compute merkle tree off-chain
      // For testing, we'll simulate this
      // unlockWithRewards expects totalAmount including base + rewards
      const baseAmount = STAKE_AMOUNT; // 1000
      const rewards = ethers.parseEther("100"); // 100 token rewards
      const totalAmount = baseAmount + rewards; // 1100 total
      
      const leaf = ethers.solidityPackedKeccak256(
        ["address", "uint256"],
        [staker1.address, totalAmount]
      );
      
      // Simple single-leaf merkle tree for testing
      const merkleRoot = leaf;
      await core.connect(validator1).updateMasterRoot(merkleRoot, 1);
      
      // Unlock with empty proof (single leaf tree)
      const balanceBefore = await token.balanceOf(staker1.address);
      await core.connect(validator1).unlockWithRewards(staker1.address, totalAmount, []);
      const balanceAfter = await token.balanceOf(staker1.address);
      
      expect(balanceAfter - balanceBefore).to.equal(totalAmount);
      
      // Check stake position cleared
      const position = await core.stakes(staker1.address);
      expect(position.amount).to.equal(0);
      expect(position.active).to.be.false;
    });
    
    it("Should reject invalid merkle proof", async function () {
      const totalAmount = STAKE_AMOUNT + ethers.parseEther("100"); // Valid amount
      const wrongRoot = ethers.randomBytes(32);
      
      await core.connect(validator1).updateMasterRoot(wrongRoot, 1);
      
      await expect(
        core.connect(validator1).unlockWithRewards(staker1.address, totalAmount, [])
      ).to.be.revertedWithCustomError(core, "InvalidProof");
    });
    
    it("Should prevent unlocking less than staked", async function () {
      const unlockAmount = ethers.parseEther("500"); // Less than staked (1000)
      const leaf = ethers.solidityPackedKeccak256(
        ["address", "uint256"],
        [staker1.address, unlockAmount]
      );
      
      await core.connect(validator1).updateMasterRoot(leaf, 1);
      
      await expect(
        core.connect(validator1).unlockWithRewards(staker1.address, unlockAmount, [])
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });
  });
  
  describe("Integration", function () {
    it("Should work with multiple stakers", async function () {
      // Multiple users stake
      await core.connect(staker1).stake(ethers.parseEther("1000"), 1, 30 * 24 * 60 * 60);
      await core.connect(staker2).stake(ethers.parseEther("2000"), 2, 60 * 24 * 60 * 60);
      
      // Check positions
      const position1 = await core.stakes(staker1.address);
      const position2 = await core.stakes(staker2.address);
      
      expect(position1.amount).to.equal(ethers.parseEther("1000"));
      expect(position1.tier).to.equal(1);
      
      expect(position2.amount).to.equal(ethers.parseEther("2000"));
      expect(position2.tier).to.equal(2);
    });
    
    it("Should handle service lookups", async function () {
      // Register all services
      await core.connect(owner).setService(ethers.id("token"), token.target);
      await core.connect(owner).setService(ethers.id("marketplace"), "0x1234567890123456789012345678901234567890");
      await core.connect(owner).setService(ethers.id("bridge"), "0x2345678901234567890123456789012345678901");
      
      // Verify lookups
      expect(await core.services(ethers.id("token"))).to.equal(token.target);
      expect(await core.services(ethers.id("nonexistent"))).to.equal(ethers.ZeroAddress);
    });
  });
});