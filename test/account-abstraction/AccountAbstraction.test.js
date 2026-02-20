const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Account Abstraction — ERC-4337 Contracts", function () {
  // ═══════════════════════════════════════════════════════════════════
  //                     OmniEntryPoint Tests
  // ═══════════════════════════════════════════════════════════════════

  describe("OmniEntryPoint", function () {
    let entryPoint;
    let deployer, alice, bob;

    beforeEach(async function () {
      [deployer, alice, bob] = await ethers.getSigners();

      const EntryPoint = await ethers.getContractFactory("OmniEntryPoint");
      entryPoint = await EntryPoint.deploy();
      await entryPoint.waitForDeployment();
    });

    it("should deploy with no constructor arguments", async function () {
      // Verify the contract is deployed and has a valid address
      const addr = await entryPoint.getAddress();
      expect(addr).to.be.properAddress;
      // Fresh contract should have zero balance for any account
      expect(await entryPoint.balanceOf(alice.address)).to.equal(0);
    });

    it("should accept deposits via depositTo and increase the account balance", async function () {
      const depositAmount = ethers.parseEther("1.5");
      await entryPoint.depositTo(alice.address, { value: depositAmount });

      expect(await entryPoint.balanceOf(alice.address)).to.equal(depositAmount);
    });

    it("should return the correct deposit via balanceOf after multiple deposits", async function () {
      const first = ethers.parseEther("1.0");
      const second = ethers.parseEther("0.25");

      await entryPoint.depositTo(alice.address, { value: first });
      await entryPoint.depositTo(alice.address, { value: second });

      expect(await entryPoint.balanceOf(alice.address)).to.equal(first + second);
    });

    it("should allow withdrawTo when deposit is sufficient", async function () {
      const depositAmount = ethers.parseEther("3.0");
      const withdrawAmount = ethers.parseEther("1.0");

      // Alice deposits to her own address via depositTo
      await entryPoint.connect(alice).depositTo(alice.address, { value: depositAmount });

      // Alice withdraws to bob
      const bobBalanceBefore = await ethers.provider.getBalance(bob.address);
      await entryPoint.connect(alice).withdrawTo(bob.address, withdrawAmount);
      const bobBalanceAfter = await ethers.provider.getBalance(bob.address);

      expect(bobBalanceAfter - bobBalanceBefore).to.equal(withdrawAmount);
      expect(await entryPoint.balanceOf(alice.address)).to.equal(
        depositAmount - withdrawAmount
      );
    });

    it("should revert withdrawTo with WithdrawalExceedsDeposit when amount exceeds deposit", async function () {
      const depositAmount = ethers.parseEther("1.0");
      const withdrawAmount = ethers.parseEther("2.0");

      await entryPoint.connect(alice).depositTo(alice.address, { value: depositAmount });

      await expect(
        entryPoint.connect(alice).withdrawTo(bob.address, withdrawAmount)
      ).to.be.revertedWithCustomError(entryPoint, "WithdrawalExceedsDeposit");
    });

    it("should return nonce 0 for a fresh account with key 0", async function () {
      const nonce = await entryPoint.getNonce(alice.address, 0);
      expect(nonce).to.equal(0);
    });

    it("should credit msg.sender deposit when receiving ETH via receive()", async function () {
      const sendAmount = ethers.parseEther("0.5");

      await alice.sendTransaction({
        to: await entryPoint.getAddress(),
        value: sendAmount,
      });

      expect(await entryPoint.balanceOf(alice.address)).to.equal(sendAmount);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //                   OmniAccountFactory Tests
  // ═══════════════════════════════════════════════════════════════════

  describe("OmniAccountFactory", function () {
    let entryPoint, factory;
    let deployer, alice, bob;

    beforeEach(async function () {
      [deployer, alice, bob] = await ethers.getSigners();

      const EntryPoint = await ethers.getContractFactory("OmniEntryPoint");
      entryPoint = await EntryPoint.deploy();
      await entryPoint.waitForDeployment();

      const Factory = await ethers.getContractFactory("OmniAccountFactory");
      factory = await Factory.deploy(await entryPoint.getAddress());
      await factory.waitForDeployment();
    });

    it("should deploy with a valid entryPoint and create an implementation", async function () {
      const implAddr = await factory.accountImplementation();
      expect(implAddr).to.be.properAddress;
      expect(implAddr).to.not.equal(ethers.ZeroAddress);

      expect(await factory.entryPoint()).to.equal(await entryPoint.getAddress());
      expect(await factory.accountCount()).to.equal(0);
    });

    it("should revert deployment with zero address entryPoint", async function () {
      const Factory = await ethers.getContractFactory("OmniAccountFactory");
      await expect(
        Factory.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
    });

    it("should create a new account via createAccount and emit AccountCreated", async function () {
      const salt = 42;
      const tx = await factory.createAccount(alice.address, salt);
      const receipt = await tx.wait();

      // Find the AccountCreated event
      const event = receipt.logs.find((log) => {
        try {
          return factory.interface.parseLog(log)?.name === "AccountCreated";
        } catch {
          return false;
        }
      });
      expect(event).to.not.be.undefined;

      const parsed = factory.interface.parseLog(event);
      expect(parsed.args.owner).to.equal(alice.address);
      expect(parsed.args.salt).to.equal(salt);

      expect(await factory.accountCount()).to.equal(1);
    });

    it("should revert createAccount with zero address owner", async function () {
      await expect(
        factory.createAccount(ethers.ZeroAddress, 0)
      ).to.be.revertedWithCustomError(factory, "InvalidAddress");
    });

    it("should return the same address for the same (owner, salt) — idempotent", async function () {
      const salt = 100;

      const tx1 = await factory.createAccount(alice.address, salt);
      const receipt1 = await tx1.wait();
      const event1 = receipt1.logs.find((log) => {
        try {
          return factory.interface.parseLog(log)?.name === "AccountCreated";
        } catch {
          return false;
        }
      });
      const addr1 = factory.interface.parseLog(event1).args.account;

      // Second call with same params should return existing account (no new event)
      const tx2 = await factory.createAccount(alice.address, salt);
      const receipt2 = await tx2.wait();

      // The second call should NOT emit AccountCreated (account already exists)
      const event2 = receipt2.logs.find((log) => {
        try {
          return factory.interface.parseLog(log)?.name === "AccountCreated";
        } catch {
          return false;
        }
      });
      expect(event2).to.be.undefined;

      // accountCount should still be 1
      expect(await factory.accountCount()).to.equal(1);
    });

    it("should predict the correct address via getAddress before deployment", async function () {
      const salt = 77;
      // Use bracket notation to call the contract's getAddress(address,uint256)
      // since ethers v6 reserves contract.getAddress() for the deployed address.
      const predicted = await factory["getAddress(address,uint256)"](
        alice.address,
        salt
      );

      const tx = await factory.createAccount(alice.address, salt);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log) => {
        try {
          return factory.interface.parseLog(log)?.name === "AccountCreated";
        } catch {
          return false;
        }
      });
      const actual = factory.interface.parseLog(event).args.account;

      expect(predicted).to.equal(actual);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //                     OmniAccount Tests
  // ═══════════════════════════════════════════════════════════════════

  describe("OmniAccount", function () {
    let entryPoint, factory;
    let account; // OmniAccount instance
    let deployer, owner, stranger, guardian1, guardian2, sessionSigner;

    beforeEach(async function () {
      [deployer, owner, stranger, guardian1, guardian2, sessionSigner] =
        await ethers.getSigners();

      const EntryPoint = await ethers.getContractFactory("OmniEntryPoint");
      entryPoint = await EntryPoint.deploy();
      await entryPoint.waitForDeployment();

      const Factory = await ethers.getContractFactory("OmniAccountFactory");
      factory = await Factory.deploy(await entryPoint.getAddress());
      await factory.waitForDeployment();

      // Create an account owned by 'owner'
      const tx = await factory.createAccount(owner.address, 0);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log) => {
        try {
          return factory.interface.parseLog(log)?.name === "AccountCreated";
        } catch {
          return false;
        }
      });
      const accountAddr = factory.interface.parseLog(event).args.account;
      account = await ethers.getContractAt("OmniAccount", accountAddr);

      // Fund the account with ETH so it can make calls
      await deployer.sendTransaction({
        to: accountAddr,
        value: ethers.parseEther("10"),
      });
    });

    it("should have the correct owner and entryPoint after creation", async function () {
      expect(await account.owner()).to.equal(owner.address);
      expect(await account.entryPoint()).to.equal(await entryPoint.getAddress());
    });

    it("should allow the owner to execute a simple ETH transfer", async function () {
      const sendAmount = ethers.parseEther("1.0");
      const balanceBefore = await ethers.provider.getBalance(stranger.address);

      // Owner calls execute to send ETH to stranger
      await account
        .connect(owner)
        .execute(stranger.address, sendAmount, "0x");

      const balanceAfter = await ethers.provider.getBalance(stranger.address);
      expect(balanceAfter - balanceBefore).to.equal(sendAmount);
    });

    it("should revert execute when called by a non-owner / non-entryPoint", async function () {
      await expect(
        account.connect(stranger).execute(stranger.address, 0, "0x")
      ).to.be.revertedWithCustomError(account, "OnlyOwnerOrEntryPoint");
    });

    it("should execute a batch of calls via executeBatch", async function () {
      const amount1 = ethers.parseEther("0.5");
      const amount2 = ethers.parseEther("0.3");

      const g1before = await ethers.provider.getBalance(guardian1.address);
      const g2before = await ethers.provider.getBalance(guardian2.address);

      await account
        .connect(owner)
        .executeBatch(
          [guardian1.address, guardian2.address],
          [amount1, amount2],
          ["0x", "0x"]
        );

      const g1after = await ethers.provider.getBalance(guardian1.address);
      const g2after = await ethers.provider.getBalance(guardian2.address);

      expect(g1after - g1before).to.equal(amount1);
      expect(g2after - g2before).to.equal(amount2);
    });

    it("should revert executeBatch with BatchLengthMismatch when arrays differ in length", async function () {
      await expect(
        account
          .connect(owner)
          .executeBatch(
            [guardian1.address, guardian2.address],
            [ethers.parseEther("0.1")],
            ["0x", "0x"]
          )
      ).to.be.revertedWithCustomError(account, "BatchLengthMismatch");
    });

    it("should allow the owner to transferOwnership", async function () {
      await account.connect(owner).transferOwnership(stranger.address);
      expect(await account.owner()).to.equal(stranger.address);
    });

    it("should revert transferOwnership to zero address", async function () {
      await expect(
        account.connect(owner).transferOwnership(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(account, "InvalidAddress");
    });

    it("should allow the owner to addGuardian", async function () {
      await account.connect(owner).addGuardian(guardian1.address);

      expect(await account.isGuardian(guardian1.address)).to.be.true;
      expect(await account.guardianCount()).to.equal(1);
    });

    it("should revert addGuardian with AlreadyGuardian for a duplicate", async function () {
      await account.connect(owner).addGuardian(guardian1.address);

      await expect(
        account.connect(owner).addGuardian(guardian1.address)
      ).to.be.revertedWithCustomError(account, "AlreadyGuardian");
    });

    it("should revert addGuardian with InvalidAddress for zero address", async function () {
      await expect(
        account.connect(owner).addGuardian(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(account, "InvalidAddress");
    });

    it("should allow the owner to removeGuardian", async function () {
      await account.connect(owner).addGuardian(guardian1.address);
      expect(await account.isGuardian(guardian1.address)).to.be.true;

      await account.connect(owner).removeGuardian(guardian1.address);
      expect(await account.isGuardian(guardian1.address)).to.be.false;
      expect(await account.guardianCount()).to.equal(0);
    });

    it("should allow the owner to addSessionKey", async function () {
      const validUntil = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now
      const allowedTarget = ethers.ZeroAddress; // any target

      await account
        .connect(owner)
        .addSessionKey(sessionSigner.address, validUntil, allowedTarget, 0);

      const sk = await account.sessionKeys(sessionSigner.address);
      expect(sk.active).to.be.true;
      expect(sk.signer).to.equal(sessionSigner.address);
      expect(await account.sessionKeyCount()).to.equal(1);
    });

    it("should allow the owner to revokeSessionKey", async function () {
      const validUntil = Math.floor(Date.now() / 1000) + 3600;

      await account
        .connect(owner)
        .addSessionKey(sessionSigner.address, validUntil, ethers.ZeroAddress, 0);

      expect(await account.sessionKeyCount()).to.equal(1);

      await account.connect(owner).revokeSessionKey(sessionSigner.address);

      const sk = await account.sessionKeys(sessionSigner.address);
      expect(sk.active).to.be.false;
      expect(await account.sessionKeyCount()).to.equal(0);
    });

    it("should accept ETH via receive()", async function () {
      const accountAddr = await account.getAddress();
      const balanceBefore = await ethers.provider.getBalance(accountAddr);

      const sendAmount = ethers.parseEther("2.0");
      await deployer.sendTransaction({ to: accountAddr, value: sendAmount });

      const balanceAfter = await ethers.provider.getBalance(accountAddr);
      expect(balanceAfter - balanceBefore).to.equal(sendAmount);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //                     OmniPaymaster Tests
  // ═══════════════════════════════════════════════════════════════════

  describe("OmniPaymaster", function () {
    let entryPoint, mockToken, paymaster;
    let deployer, paymasterOwner, alice;

    beforeEach(async function () {
      [deployer, paymasterOwner, alice] = await ethers.getSigners();

      const EntryPoint = await ethers.getContractFactory("OmniEntryPoint");
      entryPoint = await EntryPoint.deploy();
      await entryPoint.waitForDeployment();

      // Use the contracts/test/MockERC20.sol (2-arg constructor) to avoid
      // ambiguity with the test/MockERC20.sol (3-arg constructor).
      const MockERC20 = await ethers.getContractFactory(
        "contracts/test/MockERC20.sol:MockERC20"
      );
      mockToken = await MockERC20.deploy("OmniCoin", "XOM");
      await mockToken.waitForDeployment();
      await mockToken.mint(deployer.address, ethers.parseEther("1000000"));

      const Paymaster = await ethers.getContractFactory("OmniPaymaster");
      paymaster = await Paymaster.deploy(
        await entryPoint.getAddress(),
        await mockToken.getAddress(),
        paymasterOwner.address
      );
      await paymaster.waitForDeployment();
    });

    it("should deploy with valid arguments and set immutables correctly", async function () {
      expect(await paymaster.entryPoint()).to.equal(
        await entryPoint.getAddress()
      );
      expect(await paymaster.xomToken()).to.equal(
        await mockToken.getAddress()
      );
      expect(await paymaster.owner()).to.equal(paymasterOwner.address);
    });

    it("should revert deployment with zero address entryPoint", async function () {
      const Paymaster = await ethers.getContractFactory("OmniPaymaster");
      await expect(
        Paymaster.deploy(
          ethers.ZeroAddress,
          await mockToken.getAddress(),
          paymasterOwner.address
        )
      ).to.be.revertedWithCustomError(Paymaster, "InvalidAddress");
    });

    it("should revert deployment with zero address xomToken", async function () {
      const Paymaster = await ethers.getContractFactory("OmniPaymaster");
      await expect(
        Paymaster.deploy(
          await entryPoint.getAddress(),
          ethers.ZeroAddress,
          paymasterOwner.address
        )
      ).to.be.revertedWithCustomError(Paymaster, "InvalidAddress");
    });

    it("should default freeOpsLimit to 10 (DEFAULT_FREE_OPS)", async function () {
      expect(await paymaster.freeOpsLimit()).to.equal(10);
    });

    it("should default sponsorshipEnabled to true", async function () {
      expect(await paymaster.sponsorshipEnabled()).to.be.true;
    });

    it("should allow the owner to whitelist an account", async function () {
      await paymaster
        .connect(paymasterOwner)
        .whitelistAccount(alice.address);

      expect(await paymaster.whitelisted(alice.address)).to.be.true;
    });

    it("should revert setFreeOpsLimit with ExceedsMaxLimit when above MAX_FREE_OPS", async function () {
      // MAX_FREE_OPS is 100
      await expect(
        paymaster.connect(paymasterOwner).setFreeOpsLimit(101)
      ).to.be.revertedWithCustomError(paymaster, "ExceedsMaxLimit");

      // 100 should succeed (boundary)
      await paymaster.connect(paymasterOwner).setFreeOpsLimit(100);
      expect(await paymaster.freeOpsLimit()).to.equal(100);
    });

    it("should allow the owner to toggle sponsorshipEnabled", async function () {
      await paymaster
        .connect(paymasterOwner)
        .setSponsorshipEnabled(false);
      expect(await paymaster.sponsorshipEnabled()).to.be.false;

      await paymaster
        .connect(paymasterOwner)
        .setSponsorshipEnabled(true);
      expect(await paymaster.sponsorshipEnabled()).to.be.true;
    });
  });
});
