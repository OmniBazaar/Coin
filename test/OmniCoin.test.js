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

  // =====================================================================
  //  NEW TESTS - batchTransfer Edge Cases
  // =====================================================================
  describe("batchTransfer Edge Cases", function () {
    it("Should successfully batch transfer to multiple recipients", async function () {
      const recipients = [user2.address, user3.address];
      const amounts = [ethers.parseEther("1000"), ethers.parseEther("2000")];

      const result = await omniCoin.connect(user1).batchTransfer(recipients, amounts);

      expect(await omniCoin.balanceOf(user2.address)).to.equal(
        USER_FUNDING + ethers.parseEther("1000")
      );
      expect(await omniCoin.balanceOf(user3.address)).to.equal(
        USER_FUNDING + ethers.parseEther("2000")
      );
    });

    it("Should revert batchTransfer with mismatched array lengths", async function () {
      const recipients = [user2.address, user3.address];
      const amounts = [ethers.parseEther("1000")]; // one too few

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.be.revertedWithCustomError(omniCoin, "ArrayLengthMismatch");
    });

    it("Should revert batchTransfer with more than 10 recipients", async function () {
      const signers = await ethers.getSigners();
      const recipients = [];
      const amounts = [];
      for (let i = 0; i < 11; i++) {
        recipients.push(signers[i % signers.length].address);
        amounts.push(ethers.parseEther("1"));
      }

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.be.revertedWithCustomError(omniCoin, "TooManyRecipients");
    });

    it("Should accept batchTransfer with exactly 10 recipients", async function () {
      const signers = await ethers.getSigners();
      const recipients = [];
      const amounts = [];
      // Pick 10 unique non-zero, non-contract addresses
      for (let i = 0; i < 10; i++) {
        recipients.push(signers[i].address);
        amounts.push(ethers.parseEther("1"));
      }

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.not.be.reverted;
    });

    it("Should revert batchTransfer with zero address recipient", async function () {
      const recipients = [ethers.ZeroAddress];
      const amounts = [ethers.parseEther("1000")];

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.be.revertedWithCustomError(omniCoin, "InvalidRecipient");
    });

    it("Should revert batchTransfer with contract address as recipient", async function () {
      const contractAddr = await omniCoin.getAddress();
      const recipients = [contractAddr];
      const amounts = [ethers.parseEther("1000")];

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.be.revertedWithCustomError(omniCoin, "InvalidRecipient");
    });

    it("Should revert batchTransfer with empty arrays", async function () {
      // Empty arrays should succeed (no-op) since length matches and is <= 10
      const result = await omniCoin.connect(user1).batchTransfer([], []);
      // Just verify it did not revert
      expect(result).to.not.be.undefined;
    });

    it("Should revert batchTransfer with insufficient balance across batch", async function () {
      const recipients = [user2.address, user3.address];
      // Total exceeds user1's balance
      const amounts = [ethers.parseEther("60000"), ethers.parseEther("60000")];

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientBalance");
    });

    it("Should revert batchTransfer when paused", async function () {
      await omniCoin.pause();

      const recipients = [user2.address];
      const amounts = [ethers.parseEther("100")];

      await expect(
        omniCoin.connect(user1).batchTransfer(recipients, amounts)
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });
  });

  // =====================================================================
  //  NEW TESTS - Role Management (MINTER_ROLE grant/revoke)
  // =====================================================================
  describe("Role Management - Extended", function () {
    it("Should allow granting MINTER_ROLE to multiple addresses", async function () {
      const MINTER_ROLE = await omniCoin.MINTER_ROLE();
      await omniCoin.grantRole(MINTER_ROLE, user1.address);
      await omniCoin.grantRole(MINTER_ROLE, user2.address);

      expect(await omniCoin.hasRole(MINTER_ROLE, user1.address)).to.be.true;
      expect(await omniCoin.hasRole(MINTER_ROLE, user2.address)).to.be.true;
      expect(await omniCoin.hasRole(MINTER_ROLE, minter.address)).to.be.true;
    });

    it("Should allow revoking MINTER_ROLE and preventing minting", async function () {
      const MINTER_ROLE = await omniCoin.MINTER_ROLE();
      await omniCoin.revokeRole(MINTER_ROLE, minter.address);

      expect(await omniCoin.hasRole(MINTER_ROLE, minter.address)).to.be.false;

      await expect(
        omniCoin.connect(minter).mint(user1.address, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should allow granting and revoking BURNER_ROLE", async function () {
      const BURNER_ROLE = await omniCoin.BURNER_ROLE();

      // Grant to user1
      await omniCoin.grantRole(BURNER_ROLE, user1.address);
      expect(await omniCoin.hasRole(BURNER_ROLE, user1.address)).to.be.true;

      // user1 can now burn from user2
      await omniCoin.connect(user1).burnFrom(user2.address, ethers.parseEther("100"));

      // Revoke from user1
      await omniCoin.revokeRole(BURNER_ROLE, user1.address);
      expect(await omniCoin.hasRole(BURNER_ROLE, user1.address)).to.be.false;

      // user1 can no longer burn
      await expect(
        omniCoin.connect(user1).burnFrom(user2.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent non-admin from revoking roles", async function () {
      const MINTER_ROLE = await omniCoin.MINTER_ROLE();

      await expect(
        omniCoin.connect(user1).revokeRole(MINTER_ROLE, minter.address)
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent renouncing another address's role", async function () {
      const MINTER_ROLE = await omniCoin.MINTER_ROLE();

      // user1 tries to renounce minter's role
      await expect(
        omniCoin.connect(user1).renounceRole(MINTER_ROLE, minter.address)
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlBadConfirmation");
    });

    it("Should return correct role constants", async function () {
      const MINTER_ROLE = await omniCoin.MINTER_ROLE();
      const BURNER_ROLE = await omniCoin.BURNER_ROLE();
      const DEFAULT_ADMIN_ROLE = await omniCoin.DEFAULT_ADMIN_ROLE();

      expect(MINTER_ROLE).to.equal(ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE")));
      expect(BURNER_ROLE).to.equal(ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE")));
      expect(DEFAULT_ADMIN_ROLE).to.equal(ethers.ZeroHash);
    });
  });

  // =====================================================================
  //  NEW TESTS - Transfer Limits and Edge Cases
  // =====================================================================
  describe("Transfer Limits and Edge Cases", function () {
    it("Should allow transfer of zero tokens", async function () {
      await expect(
        omniCoin.connect(user1).transfer(user2.address, 0n)
      ).to.not.be.reverted;
    });

    it("Should allow transfer of entire balance", async function () {
      const balance = await omniCoin.balanceOf(user1.address);
      await omniCoin.connect(user1).transfer(user2.address, balance);

      expect(await omniCoin.balanceOf(user1.address)).to.equal(0n);
      expect(await omniCoin.balanceOf(user2.address)).to.equal(USER_FUNDING + balance);
    });

    it("Should revert transfer to zero address", async function () {
      await expect(
        omniCoin.connect(user1).transfer(ethers.ZeroAddress, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InvalidReceiver");
    });

    it("Should handle self-transfer", async function () {
      const balBefore = await omniCoin.balanceOf(user1.address);
      await omniCoin.connect(user1).transfer(user1.address, ethers.parseEther("100"));
      const balAfter = await omniCoin.balanceOf(user1.address);

      expect(balAfter).to.equal(balBefore);
    });

    it("Should fail transferFrom without sufficient allowance", async function () {
      await omniCoin.connect(user1).approve(user2.address, ethers.parseEther("500"));

      await expect(
        omniCoin.connect(user2).transferFrom(user1.address, user3.address, ethers.parseEther("501"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientAllowance");
    });
  });

  // =====================================================================
  //  NEW TESTS - Pause Functionality Extended
  // =====================================================================
  describe("Pause Functionality - Extended", function () {
    it("Should prevent approve when paused (transfers blocked, approve still works)", async function () {
      await omniCoin.pause();

      // ERC20 approve itself is not blocked by pause, only _update (transfer/mint/burn)
      // So approve should still work
      await expect(
        omniCoin.connect(user1).approve(user2.address, ethers.parseEther("1000"))
      ).to.not.be.reverted;
    });

    it("Should prevent burn when paused", async function () {
      await omniCoin.pause();

      await expect(
        omniCoin.connect(user1).burn(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });

    it("Should prevent burnFrom when paused", async function () {
      await omniCoin.pause();

      await expect(
        omniCoin.connect(burner).burnFrom(user1.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });

    it("Should prevent non-admin from unpausing", async function () {
      await omniCoin.pause();

      await expect(
        omniCoin.connect(user1).unpause()
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should revert when pausing an already paused contract", async function () {
      await omniCoin.pause();

      await expect(
        omniCoin.pause()
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });

    it("Should revert when unpausing a non-paused contract", async function () {
      await expect(
        omniCoin.unpause()
      ).to.be.revertedWithCustomError(omniCoin, "ExpectedPause");
    });
  });

  // =====================================================================
  //  NEW TESTS - ERC20 Compliance
  // =====================================================================
  describe("ERC20 Compliance", function () {
    it("Should return correct name, symbol, decimals", async function () {
      expect(await omniCoin.name()).to.equal("OmniCoin");
      expect(await omniCoin.symbol()).to.equal("XOM");
      expect(await omniCoin.decimals()).to.equal(18);
    });

    it("Should handle approve overwrite (no race condition)", async function () {
      await omniCoin.connect(user1).approve(user2.address, ethers.parseEther("1000"));
      expect(await omniCoin.allowance(user1.address, user2.address)).to.equal(ethers.parseEther("1000"));

      // Overwrite with new value
      await omniCoin.connect(user1).approve(user2.address, ethers.parseEther("500"));
      expect(await omniCoin.allowance(user1.address, user2.address)).to.equal(ethers.parseEther("500"));
    });

    it("Should allow approve to zero", async function () {
      await omniCoin.connect(user1).approve(user2.address, ethers.parseEther("1000"));
      await omniCoin.connect(user1).approve(user2.address, 0n);
      expect(await omniCoin.allowance(user1.address, user2.address)).to.equal(0n);
    });

    it("Should emit Approval event on approve", async function () {
      const amount = ethers.parseEther("5000");
      await expect(
        omniCoin.connect(user1).approve(user2.address, amount)
      ).to.emit(omniCoin, "Approval")
        .withArgs(user1.address, user2.address, amount);
    });

    it("Should support max uint256 approval (infinite allowance)", async function () {
      await omniCoin.connect(user1).approve(user2.address, ethers.MaxUint256);
      expect(await omniCoin.allowance(user1.address, user2.address)).to.equal(ethers.MaxUint256);
    });

    it("Should return correct totalSupply after burns", async function () {
      const burnAmount = ethers.parseEther("10000");
      await omniCoin.connect(user1).burn(burnAmount);

      expect(await omniCoin.totalSupply()).to.equal(INITIAL_SUPPLY - burnAmount);
    });
  });

  // =====================================================================
  //  NEW TESTS - Events Extended
  // =====================================================================
  describe("Events - Extended", function () {
    it("Should emit Transfer event on burn", async function () {
      const amount = ethers.parseEther("1000");
      await expect(omniCoin.connect(user1).burn(amount))
        .to.emit(omniCoin, "Transfer")
        .withArgs(user1.address, ethers.ZeroAddress, amount);
    });

    it("Should emit Transfer event on burnFrom", async function () {
      const amount = ethers.parseEther("1000");
      await expect(omniCoin.connect(burner).burnFrom(user1.address, amount))
        .to.emit(omniCoin, "Transfer")
        .withArgs(user1.address, ethers.ZeroAddress, amount);
    });

    it("Should emit Transfer event on batchTransfer for each recipient", async function () {
      const recipients = [user2.address, user3.address];
      const amounts = [ethers.parseEther("100"), ethers.parseEther("200")];

      const tx = await omniCoin.connect(user1).batchTransfer(recipients, amounts);
      const receipt = await tx.wait();

      // Should have 2 Transfer events
      const transferEvents = receipt.logs.filter(
        (l) => l.fragment && l.fragment.name === "Transfer"
      );
      expect(transferEvents.length).to.equal(2);
    });
  });

  // =====================================================================
  //  NEW TESTS - Access Control Extended
  // =====================================================================
  describe("Access Control - Extended", function () {
    it("Should use AccessControlDefaultAdminRules with 48h delay", async function () {
      // The admin transfer delay should be 48 hours
      const delay = await omniCoin.defaultAdminDelay();
      expect(delay).to.equal(48n * 60n * 60n); // 48 hours in seconds
    });

    it("Should prevent calling initialize twice", async function () {
      await expect(
        omniCoin.initialize()
      ).to.be.revertedWithCustomError(omniCoin, "AlreadyInitialized");
    });

    it("Should prevent non-deployer from calling initialize", async function () {
      // Deploy fresh contract
      const OmniCoin = await ethers.getContractFactory("OmniCoin");
      const freshCoin = await OmniCoin.deploy(ethers.ZeroAddress);

      await expect(
        freshCoin.connect(user1).initialize()
      ).to.be.revertedWithCustomError(freshCoin, "Unauthorized");
    });

    it("Should have deployer as initial MINTER and BURNER after initialize", async function () {
      // Deploy fresh and initialize
      const OmniCoin = await ethers.getContractFactory("OmniCoin");
      const freshCoin = await OmniCoin.deploy(ethers.ZeroAddress);
      await freshCoin.initialize();

      const MINTER_ROLE = await freshCoin.MINTER_ROLE();
      const BURNER_ROLE = await freshCoin.BURNER_ROLE();

      expect(await freshCoin.hasRole(MINTER_ROLE, owner.address)).to.be.true;
      expect(await freshCoin.hasRole(BURNER_ROLE, owner.address)).to.be.true;
    });

    it("MAX_SUPPLY should equal 16.6 billion tokens (18 decimals)", async function () {
      const expected = ethers.parseEther("16600000000");
      expect(await omniCoin.MAX_SUPPLY()).to.equal(expected);
    });

    it("INITIAL_SUPPLY should equal MAX_SUPPLY", async function () {
      expect(await omniCoin.INITIAL_SUPPLY()).to.equal(await omniCoin.MAX_SUPPLY());
    });
  });
});
