const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// Helper functions for ethers v6 compatibility
const parseEther = ethers.parseEther;
const ZeroAddress = ethers.ZeroAddress;

describe("OmniCoin Security Tests (Fixed)", function () {
  // Set timeout for each test
  this.timeout(10000);

  async function deployOmniCoinFixture() {
    const [owner, attacker, user1, user2] = await ethers.getSigners();

    // Deploy mock dependency contracts
    const MockConfig = await ethers.getContractFactory("OmniCoinConfig");
    const config = await MockConfig.deploy(owner.address);
    await config.waitForDeployment();

    const MockReputation = await ethers.getContractFactory("OmniCoinReputation");
    const reputation = await MockReputation.deploy(await config.getAddress(), owner.address);
    await reputation.waitForDeployment();

    const MockStaking = await ethers.getContractFactory("OmniCoinStaking");
    const staking = await MockStaking.deploy(await config.getAddress(), owner.address);
    await staking.waitForDeployment();

    const MockValidator = await ethers.getContractFactory("OmniCoinValidator");
    const validator = await MockValidator.deploy(ZeroAddress, owner.address);
    await validator.waitForDeployment();

    const MockMultisig = await ethers.getContractFactory("OmniCoinMultisig");
    const multisig = await MockMultisig.deploy(owner.address);
    await multisig.waitForDeployment();

    const MockPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
    const privacy = await MockPrivacy.deploy(ZeroAddress, owner.address);
    await privacy.waitForDeployment();

    const MockGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
    const garbledCircuit = await MockGarbledCircuit.deploy(owner.address);
    await garbledCircuit.waitForDeployment();

    const MockGovernor = await ethers.getContractFactory("OmniCoinGovernor");
    const governor = await MockGovernor.deploy(ZeroAddress, owner.address);
    await governor.waitForDeployment();

    const MockEscrow = await ethers.getContractFactory("OmniCoinEscrow");
    const escrow = await MockEscrow.deploy(ZeroAddress, owner.address);
    await escrow.waitForDeployment();

    const MockBridge = await ethers.getContractFactory("OmniCoinBridge");
    const bridge = await MockBridge.deploy(ZeroAddress, owner.address);
    await bridge.waitForDeployment();

    // Deploy main contract
    const OmniCoin = await ethers.getContractFactory("contracts/OmniCoin.sol:OmniCoin");
    const omniCoin = await OmniCoin.deploy(
      owner.address,
      await config.getAddress(),
      await reputation.getAddress(),
      await staking.getAddress(),
      await validator.getAddress(),
      await multisig.getAddress(),
      await privacy.getAddress(),
      await garbledCircuit.getAddress(),
      await governor.getAddress(),
      await escrow.getAddress(),
      await bridge.getAddress()
    );
    await omniCoin.waitForDeployment();

    return { omniCoin, owner, attacker, user1, user2, config, reputation, staking, validator, multisig, privacy, garbledCircuit, governor, escrow, bridge };
  }

  describe("Access Control Security", function () {
    it("Should prevent unauthorized minting", async function () {
      const { omniCoin, attacker } = await loadFixture(deployOmniCoinFixture);

      await expect(
        omniCoin.connect(attacker).mint(attacker.address, parseEther("1000"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent unauthorized burning", async function () {
      const { omniCoin, attacker } = await loadFixture(deployOmniCoinFixture);

      await expect(
        omniCoin.connect(attacker).burn(parseEther("1000"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent unauthorized pausing", async function () {
      const { omniCoin, attacker } = await loadFixture(deployOmniCoinFixture);

      await expect(omniCoin.connect(attacker).pause())
        .to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should allow proper role-based access", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      // Owner should be able to mint
      await omniCoin.connect(owner).mint(user1.address, parseEther("1000"));
      expect(await omniCoin.balanceOf(user1.address)).to.equal(parseEther("1000"));

      // Owner should be able to pause
      await omniCoin.connect(owner).pause();
      expect(await omniCoin.paused()).to.be.true;

      // Owner should be able to unpause
      await omniCoin.connect(owner).unpause();
      expect(await omniCoin.paused()).to.be.false;
    });
  });

  describe("Input Validation", function () {
    it("Should reject zero address transfers", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));

      await expect(
        omniCoin.transfer(ZeroAddress, parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InvalidReceiver");
    });

    it("Should reject transfers exceeding balance", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("100"));

      await expect(
        omniCoin.transfer(user1.address, parseEther("200"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientBalance");
    });

    it("Should handle zero amount transfers", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));

      // Zero amount transfer should succeed but not change balances
      await expect(omniCoin.transfer(user1.address, 0)).to.not.be.reverted;
      expect(await omniCoin.balanceOf(user1.address)).to.equal(0);
    });
  });

  describe("Pausable Security", function () {
    it("Should prevent transfers when paused", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));
      await omniCoin.pause();

      await expect(
        omniCoin.transfer(user1.address, parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });

    it("Should allow transfers after unpause", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));
      await omniCoin.pause();
      await omniCoin.unpause();

      await expect(omniCoin.transfer(user1.address, parseEther("100"))).to.not.be.reverted;
      expect(await omniCoin.balanceOf(user1.address)).to.equal(parseEther("100"));
    });
  });

  describe("Token Economics Security", function () {
    it("Should maintain total supply integrity", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      const mintAmount = parseEther("1000");
      await omniCoin.mint(owner.address, mintAmount);

      expect(await omniCoin.totalSupply()).to.equal(mintAmount);
      
      await omniCoin.transfer(user1.address, parseEther("300"));
      
      // Total supply should remain the same after transfer
      expect(await omniCoin.totalSupply()).to.equal(mintAmount);
    });

    it("Should handle burning correctly", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);

      const mintAmount = parseEther("1000");
      const burnAmount = parseEther("300");
      
      await omniCoin.mint(owner.address, mintAmount);
      await omniCoin.burn(burnAmount);

      expect(await omniCoin.totalSupply()).to.equal(mintAmount - burnAmount);
      expect(await omniCoin.balanceOf(owner.address)).to.equal(mintAmount - burnAmount);
    });
  });

  describe("Event Security", function () {
    it("Should emit events for security-relevant actions", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      // Test minting event
      await expect(omniCoin.mint(owner.address, parseEther("1000")))
        .to.emit(omniCoin, "Transfer")
        .withArgs(ZeroAddress, owner.address, parseEther("1000"));

      // Test multisig threshold change event
      await expect(omniCoin.setMultisigThreshold(parseEther("2000")))
        .to.emit(omniCoin, "MultisigThresholdUpdated");
    });
  });
}); 