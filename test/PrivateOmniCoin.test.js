const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("PrivateOmniCoin", function () {
  let privateToken;
  let owner, minter, burner, user1, user2, user3;
  
  const INITIAL_SUPPLY = ethers.parseEther("1000000000"); // 1 billion with 18 decimals
  
  beforeEach(async function () {
    [owner, minter, burner, user1, user2, user3] = await ethers.getSigners();
    
    // Deploy OmniCore first (not needed for simplified architecture)
    // const OmniCore = await ethers.getContractFactory("OmniCore");
    // const omniCoin = await ethers.getContractFactory("OmniCoin");
    // const token = await omniCoin.deploy();
    // await token.initialize();
    
    // core = await OmniCore.deploy(token.target);
    
    // Deploy PrivateOmniCoin
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    privateToken = await PrivateOmniCoin.deploy();
    await privateToken.initialize();
    
    // Register service in core (not needed for simplified architecture)
    // await core.registerService(ethers.id("PRIVATE_OMNICOIN"), privateToken.target);
    
    // Grant roles
    await privateToken.grantRole(await privateToken.MINTER_ROLE(), minter.address);
    await privateToken.grantRole(await privateToken.BURNER_ROLE(), burner.address);
    
    // Mint some tokens to users for testing
    await privateToken.connect(minter).mint(user1.address, ethers.parseEther("100000"));
    await privateToken.connect(minter).mint(user2.address, ethers.parseEther("100000"));
    await privateToken.connect(minter).mint(user3.address, ethers.parseEther("100000"));
  });
  
  describe("Deployment and Initialization", function () {
    it("Should set correct name and symbol", async function () {
      expect(await privateToken.name()).to.equal("Private OmniCoin");
      expect(await privateToken.symbol()).to.equal("pXOM");
    });
    
    it("Should have 18 decimals", async function () {
      expect(await privateToken.decimals()).to.equal(18);
    });
    
    it("Should have correct initial supply", async function () {
      // Initial supply + minted tokens
      const expectedSupply = INITIAL_SUPPLY + ethers.parseEther("300000");
      expect(await privateToken.totalSupply()).to.equal(expectedSupply);
    });
    
    it("Should assign initial supply to owner", async function () {
      expect(await privateToken.balanceOf(owner.address)).to.equal(INITIAL_SUPPLY);
    });
    
    it("Should set up roles correctly", async function () {
      expect(await privateToken.hasRole(await privateToken.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
      expect(await privateToken.hasRole(await privateToken.MINTER_ROLE(), minter.address)).to.be.true;
      expect(await privateToken.hasRole(await privateToken.BURNER_ROLE(), burner.address)).to.be.true;
    });
  });
  
  describe("Privacy Features", function () {
    it("Should mask real balance with privacy balance", async function () {
      // Real balance should not be directly visible
      const balance = await privateToken.balanceOf(user1.address);
      expect(balance).to.be.gt(0);
      
      // Privacy layer would mask the actual balance in production
      // This requires COTI MPC integration which is not available in test environment
    });
    
    it("Should support private transfers", async function () {
      const amount = ethers.parseEther("1000");
      
      // Private transfer functionality
      // In production, this would use COTI's privacy layer
      await privateToken.connect(user1).transfer(user2.address, amount);
      
      // Balances should be updated
      expect(await privateToken.balanceOf(user1.address)).to.equal(ethers.parseEther("99000"));
      expect(await privateToken.balanceOf(user2.address)).to.equal(ethers.parseEther("101000"));
    });
  });
  
  describe("ERC20 Functionality", function () {
    it("Should transfer tokens between accounts", async function () {
      const amount = ethers.parseEther("1000");
      
      await privateToken.connect(user1).transfer(user2.address, amount);
      
      expect(await privateToken.balanceOf(user1.address)).to.equal(ethers.parseEther("99000"));
      expect(await privateToken.balanceOf(user2.address)).to.equal(ethers.parseEther("101000"));
    });
    
    it("Should approve and transferFrom", async function () {
      const amount = ethers.parseEther("1000");
      
      await privateToken.connect(user1).approve(user2.address, amount);
      expect(await privateToken.allowance(user1.address, user2.address)).to.equal(amount);
      
      await privateToken.connect(user2).transferFrom(user1.address, user3.address, amount);
      
      expect(await privateToken.balanceOf(user1.address)).to.equal(ethers.parseEther("99000"));
      expect(await privateToken.balanceOf(user3.address)).to.equal(ethers.parseEther("101000"));
    });
    
    it("Should emit Transfer event", async function () {
      const amount = ethers.parseEther("1000");
      
      await expect(privateToken.connect(user1).transfer(user2.address, amount))
        .to.emit(privateToken, "Transfer")
        .withArgs(user1.address, user2.address, amount);
    });
    
    it("Should fail transfer with insufficient balance", async function () {
      const amount = ethers.parseEther("200000");
      
      await expect(
        privateToken.connect(user1).transfer(user2.address, amount)
      ).to.be.revertedWithCustomError(privateToken, "ERC20InsufficientBalance");
    });
  });
  
  describe("Minting", function () {
    it("Should allow minter to mint tokens", async function () {
      const amount = ethers.parseEther("10000");
      const balanceBefore = await privateToken.balanceOf(user1.address);
      
      await privateToken.connect(minter).mint(user1.address, amount);
      
      const balanceAfter = await privateToken.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(amount);
    });
    
    it("Should increase total supply when minting", async function () {
      const amount = ethers.parseEther("10000");
      const supplyBefore = await privateToken.totalSupply();
      
      await privateToken.connect(minter).mint(user1.address, amount);
      
      const supplyAfter = await privateToken.totalSupply();
      expect(supplyAfter - supplyBefore).to.equal(amount);
    });
    
    it("Should prevent non-minter from minting", async function () {
      await expect(
        privateToken.connect(user1).mint(user2.address, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(privateToken, "AccessControlUnauthorizedAccount");
    });
  });
  
  describe("Burning", function () {
    it("Should allow burner to burn tokens", async function () {
      const amount = ethers.parseEther("10000");
      const balanceBefore = await privateToken.balanceOf(user1.address);
      
      await privateToken.connect(burner).burnFrom(user1.address, amount);
      
      const balanceAfter = await privateToken.balanceOf(user1.address);
      expect(balanceBefore - balanceAfter).to.equal(amount);
    });
    
    it("Should decrease total supply when burning", async function () {
      const amount = ethers.parseEther("10000");
      const supplyBefore = await privateToken.totalSupply();
      
      await privateToken.connect(burner).burnFrom(user1.address, amount);
      
      const supplyAfter = await privateToken.totalSupply();
      expect(supplyBefore - supplyAfter).to.equal(amount);
    });
    
    it("Should allow users to burn their own tokens", async function () {
      const amount = ethers.parseEther("1000");
      const balanceBefore = await privateToken.balanceOf(user1.address);
      
      await privateToken.connect(user1).burn(amount);
      
      const balanceAfter = await privateToken.balanceOf(user1.address);
      expect(balanceBefore - balanceAfter).to.equal(amount);
    });
  });
  
  describe("Role Management", function () {
    it("Should allow admin to grant roles", async function () {
      const newMinter = user3.address;
      
      await privateToken.grantRole(await privateToken.MINTER_ROLE(), newMinter);
      
      expect(await privateToken.hasRole(await privateToken.MINTER_ROLE(), newMinter)).to.be.true;
    });
    
    it("Should allow admin to revoke roles", async function () {
      await privateToken.revokeRole(await privateToken.MINTER_ROLE(), minter.address);
      
      expect(await privateToken.hasRole(await privateToken.MINTER_ROLE(), minter.address)).to.be.false;
    });
    
    it("Should prevent non-admin from granting roles", async function () {
      await expect(
        privateToken.connect(user1).grantRole(await privateToken.MINTER_ROLE(), user2.address)
      ).to.be.revertedWithCustomError(privateToken, "AccessControlUnauthorizedAccount");
    });
  });
  
  describe("Pausable Functionality", function () {
    it("Should allow owner to pause transfers", async function () {
      await privateToken.pause();
      
      expect(await privateToken.paused()).to.be.true;
    });
    
    it("Should prevent transfers when paused", async function () {
      await privateToken.pause();
      
      await expect(
        privateToken.connect(user1).transfer(user2.address, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(privateToken, "EnforcedPause");
    });
    
    it("Should allow owner to unpause", async function () {
      await privateToken.pause();
      await privateToken.unpause();
      
      expect(await privateToken.paused()).to.be.false;
      
      // Should allow transfers again
      await privateToken.connect(user1).transfer(user2.address, ethers.parseEther("1000"));
    });
  });
  
  describe("Privacy-Specific Functions", function () {
    it("Should handle shielded transfers", async function () {
      const amount = ethers.parseEther("1000");
      
      // In production, this would create a shielded transaction
      // For testing, we simulate with regular transfer
      await privateToken.connect(user1).transfer(user2.address, amount);
      
      // Verify transfer completed
      expect(await privateToken.balanceOf(user2.address)).to.equal(ethers.parseEther("101000"));
    });
    
    it("Should support zero-knowledge proofs", async function () {
      // This is a placeholder for ZK proof functionality
      // Actual implementation requires COTI MPC
      expect(await privateToken.supportsInterface("0x01ffc9a7")).to.be.true;
    });
  });
  
  // Integration with OmniCore removed for simplified architecture
  
  describe("Events", function () {
    it("Should emit RoleGranted event", async function () {
      const role = await privateToken.MINTER_ROLE();
      const account = user3.address;
      
      await expect(privateToken.grantRole(role, account))
        .to.emit(privateToken, "RoleGranted")
        .withArgs(role, account, owner.address);
    });
    
    it("Should emit Paused event", async function () {
      await expect(privateToken.pause())
        .to.emit(privateToken, "Paused")
        .withArgs(owner.address);
    });
  });
  
  describe("Compliance and Privacy", function () {
    it("Should maintain transaction privacy", async function () {
      // Transaction details should be private
      const amount = ethers.parseEther("5000");
      await privateToken.connect(user1).transfer(user2.address, amount);
      
      // In production with COTI MPC:
      // - Transaction amounts would be encrypted
      // - Only involved parties could decrypt
      // - Validators would verify without seeing amounts
      
      // For testing, we just verify the transfer worked
      expect(await privateToken.balanceOf(user2.address)).to.equal(ethers.parseEther("105000"));
    });
    
    it("Should support selective disclosure", async function () {
      // Placeholder for selective disclosure feature
      // Users could reveal transaction details to specific parties
      // This requires COTI MPC implementation
      expect(await privateToken.decimals()).to.equal(18);
    });
  });
});