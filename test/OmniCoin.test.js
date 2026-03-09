const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoin", function () {
  let omniCoin;
  let owner, minter, burner, user1, user2, user3;
  
  const INITIAL_SUPPLY = ethers.parseEther("16600000000"); // 16.6 billion (full pre-mint at genesis)
  const USER_FUNDING = ethers.parseEther("100000"); // 100K per test user

  beforeEach(async function () {
    [owner, minter, burner, user1, user2, user3] = await ethers.getSigners();

    // Deploy OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    omniCoin = await OmniCoin.deploy(ethers.ZeroAddress);
    await omniCoin.initialize();

    // Grant roles
    await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), minter.address);
    await omniCoin.grantRole(await omniCoin.BURNER_ROLE(), burner.address);

    // Transfer tokens from deployer to users for testing
    // (In production, no minting after genesis — all distribution via transfer)
    await omniCoin.transfer(user1.address, USER_FUNDING);
    await omniCoin.transfer(user2.address, USER_FUNDING);
    await omniCoin.transfer(user3.address, USER_FUNDING);
  });
  
  describe("Deployment and Initialization", function () {
    it("Should set correct name and symbol", async function () {
      expect(await omniCoin.name()).to.equal("OmniCoin");
      expect(await omniCoin.symbol()).to.equal("XOM");
    });
    
    it("Should have 18 decimals", async function () {
      expect(await omniCoin.decimals()).to.equal(18);
    });
    
    it("Should have correct initial supply", async function () {
      // All 16.6B minted at genesis, total supply unchanged (transfers don't change supply)
      expect(await omniCoin.totalSupply()).to.equal(INITIAL_SUPPLY);
    });

    it("Should assign initial supply to owner minus transferred amounts", async function () {
      // Owner started with full supply, then transferred 100K to each of 3 users
      const expectedOwnerBalance = INITIAL_SUPPLY - USER_FUNDING * 3n;
      expect(await omniCoin.balanceOf(owner.address)).to.equal(expectedOwnerBalance);
    });
    
    it("Should set up roles correctly", async function () {
      expect(await omniCoin.hasRole(await omniCoin.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
      expect(await omniCoin.hasRole(await omniCoin.MINTER_ROLE(), minter.address)).to.be.true;
      expect(await omniCoin.hasRole(await omniCoin.BURNER_ROLE(), burner.address)).to.be.true;
    });
  });
  
  describe("ERC20 Functionality", function () {
    it("Should transfer tokens between accounts", async function () {
      const amount = ethers.parseEther("1000");
      
      await omniCoin.connect(user1).transfer(user2.address, amount);
      
      expect(await omniCoin.balanceOf(user1.address)).to.equal(ethers.parseEther("99000"));
      expect(await omniCoin.balanceOf(user2.address)).to.equal(ethers.parseEther("101000"));
    });
    
    it("Should approve and transferFrom", async function () {
      const amount = ethers.parseEther("1000");
      
      await omniCoin.connect(user1).approve(user2.address, amount);
      expect(await omniCoin.allowance(user1.address, user2.address)).to.equal(amount);
      
      await omniCoin.connect(user2).transferFrom(user1.address, user3.address, amount);
      
      expect(await omniCoin.balanceOf(user1.address)).to.equal(ethers.parseEther("99000"));
      expect(await omniCoin.balanceOf(user3.address)).to.equal(ethers.parseEther("101000"));
    });
    
    it("Should fail transfer with insufficient balance", async function () {
      const amount = ethers.parseEther("200000");
      
      await expect(
        omniCoin.connect(user1).transfer(user2.address, amount)
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientBalance");
    });
    
    it("Should emit Transfer event", async function () {
      const amount = ethers.parseEther("1000");
      
      await expect(omniCoin.connect(user1).transfer(user2.address, amount))
        .to.emit(omniCoin, "Transfer")
        .withArgs(user1.address, user2.address, amount);
    });
  });
  
  describe("Minting", function () {
    it("Should reject minting when supply is at MAX_SUPPLY", async function () {
      // In production architecture, all 16.6B is pre-minted at genesis.
      // Any further minting should fail with ExceedsMaxSupply.
      const amount = ethers.parseEther("1");
      await expect(
        omniCoin.connect(minter).mint(user1.address, amount)
      ).to.be.revertedWithCustomError(omniCoin, "ExceedsMaxSupply");
    });

    it("Should prevent non-minter from minting", async function () {
      await expect(
        omniCoin.connect(user1).mint(user2.address, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should confirm INITIAL_SUPPLY equals MAX_SUPPLY", async function () {
      expect(await omniCoin.INITIAL_SUPPLY()).to.equal(await omniCoin.MAX_SUPPLY());
    });
  });
  
  describe("Burning", function () {
    it("Should allow burner to burn tokens", async function () {
      const amount = ethers.parseEther("10000");
      const balanceBefore = await omniCoin.balanceOf(user1.address);
      
      await omniCoin.connect(burner).burnFrom(user1.address, amount);
      
      const balanceAfter = await omniCoin.balanceOf(user1.address);
      expect(balanceBefore - balanceAfter).to.equal(amount);
    });
    
    it("Should decrease total supply when burning", async function () {
      const amount = ethers.parseEther("10000");
      const supplyBefore = await omniCoin.totalSupply();
      
      await omniCoin.connect(burner).burnFrom(user1.address, amount);
      
      const supplyAfter = await omniCoin.totalSupply();
      expect(supplyBefore - supplyAfter).to.equal(amount);
    });
    
    it("Should prevent non-burner from burning", async function () {
      await expect(
        omniCoin.connect(user1).burnFrom(user2.address, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });
    
    it("Should allow users to burn their own tokens", async function () {
      const amount = ethers.parseEther("1000");
      const balanceBefore = await omniCoin.balanceOf(user1.address);
      
      await omniCoin.connect(user1).burn(amount);
      
      const balanceAfter = await omniCoin.balanceOf(user1.address);
      expect(balanceBefore - balanceAfter).to.equal(amount);
    });
  });
  
  describe("Role Management", function () {
    it("Should allow admin to grant roles", async function () {
      const newMinter = user3.address;
      
      await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), newMinter);
      
      expect(await omniCoin.hasRole(await omniCoin.MINTER_ROLE(), newMinter)).to.be.true;
    });
    
    it("Should allow admin to revoke roles", async function () {
      await omniCoin.revokeRole(await omniCoin.MINTER_ROLE(), minter.address);
      
      expect(await omniCoin.hasRole(await omniCoin.MINTER_ROLE(), minter.address)).to.be.false;
    });
    
    it("Should prevent non-admin from granting roles", async function () {
      await expect(
        omniCoin.connect(user1).grantRole(await omniCoin.MINTER_ROLE(), user2.address)
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });
    
    it("Should allow role renunciation", async function () {
      await omniCoin.connect(minter).renounceRole(await omniCoin.MINTER_ROLE(), minter.address);
      
      expect(await omniCoin.hasRole(await omniCoin.MINTER_ROLE(), minter.address)).to.be.false;
    });
  });
  
  describe("Pausable Functionality", function () {
    it("Should allow owner to pause transfers", async function () {
      await omniCoin.pause();
      
      expect(await omniCoin.paused()).to.be.true;
    });
    
    it("Should prevent transfers when paused", async function () {
      await omniCoin.pause();
      
      await expect(
        omniCoin.connect(user1).transfer(user2.address, ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });
    
    it("Should allow owner to unpause", async function () {
      await omniCoin.pause();
      await omniCoin.unpause();
      
      expect(await omniCoin.paused()).to.be.false;
      
      // Should allow transfers again
      await omniCoin.connect(user1).transfer(user2.address, ethers.parseEther("1000"));
    });
    
    it("Should prevent non-owner from pausing", async function () {
      await expect(
        omniCoin.connect(user1).pause()
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });
  });
  
  describe("ERC20Permit Functionality", function () {
    it("Should support permit", async function () {
      const amount = ethers.parseEther("1000");
      const deadline = ethers.MaxUint256;
      
      // Create permit signature
      const nonce = await omniCoin.nonces(user1.address);
      const domain = {
        name: await omniCoin.name(),
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await omniCoin.getAddress()
      };
      
      const types = {
        Permit: [
          { name: "owner", type: "address" },
          { name: "spender", type: "address" },
          { name: "value", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" }
        ]
      };
      
      const value = {
        owner: user1.address,
        spender: user2.address,
        value: amount,
        nonce: nonce,
        deadline: deadline
      };
      
      const signature = await user1.signTypedData(domain, types, value);
      const { v, r, s } = ethers.Signature.from(signature);
      
      // Use permit
      await omniCoin.permit(user1.address, user2.address, amount, deadline, v, r, s);
      
      expect(await omniCoin.allowance(user1.address, user2.address)).to.equal(amount);
    });
  });
  
  describe("Events", function () {
    it("Should emit RoleGranted event", async function () {
      const role = await omniCoin.MINTER_ROLE();
      const account = user3.address;
      
      await expect(omniCoin.grantRole(role, account))
        .to.emit(omniCoin, "RoleGranted")
        .withArgs(role, account, owner.address);
    });
    
    it("Should emit RoleRevoked event", async function () {
      const role = await omniCoin.MINTER_ROLE();
      
      await expect(omniCoin.revokeRole(role, minter.address))
        .to.emit(omniCoin, "RoleRevoked")
        .withArgs(role, minter.address, owner.address);
    });
    
    it("Should emit Paused event", async function () {
      await expect(omniCoin.pause())
        .to.emit(omniCoin, "Paused")
        .withArgs(owner.address);
    });
    
    it("Should emit Unpaused event", async function () {
      await omniCoin.pause();
      
      await expect(omniCoin.unpause())
        .to.emit(omniCoin, "Unpaused")
        .withArgs(owner.address);
    });
  });
  
  describe("Integration Scenarios", function () {
    it("Should handle complex transfer scenarios", async function () {
      // User1 transfers to User2
      await omniCoin.connect(user1).transfer(user2.address, ethers.parseEther("10000"));
      
      // User2 approves User3
      await omniCoin.connect(user2).approve(user3.address, ethers.parseEther("5000"));
      
      // User3 transfers from User2 to User1
      await omniCoin.connect(user3).transferFrom(user2.address, user1.address, ethers.parseEther("5000"));
      
      // Check final balances
      expect(await omniCoin.balanceOf(user1.address)).to.equal(ethers.parseEther("95000"));
      expect(await omniCoin.balanceOf(user2.address)).to.equal(ethers.parseEther("105000"));
      expect(await omniCoin.balanceOf(user3.address)).to.equal(ethers.parseEther("100000"));
    });
    
    it("Should handle role-based operations", async function () {
      // Owner transfers additional tokens to user1 (simulating pool distribution)
      await omniCoin.transfer(user1.address, ethers.parseEther("50000"));

      // User1 burns some of their tokens
      await omniCoin.connect(user1).burn(ethers.parseEther("25000"));

      // Burner burns from User1
      await omniCoin.connect(burner).burnFrom(user1.address, ethers.parseEther("25000"));

      // Check final balance (started 100K + received 50K - burned 25K - burned 25K = 100K)
      expect(await omniCoin.balanceOf(user1.address)).to.equal(ethers.parseEther("100000"));
    });
  });
});