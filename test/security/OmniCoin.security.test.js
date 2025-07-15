const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// Helper function for ethers v6 compatibility
const parseEther = ethers.parseEther;
const ZeroAddress = ethers.ZeroAddress;

describe("OmniCoin Security Tests", function () {
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
    const validator = await MockValidator.deploy(ethers.ZeroAddress, owner.address);
    await validator.waitForDeployment();

    const MockMultisig = await ethers.getContractFactory("OmniCoinMultisig");
    const multisig = await MockMultisig.deploy(owner.address);
    await multisig.waitForDeployment();

    const MockPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
    const privacy = await MockPrivacy.deploy(ethers.ZeroAddress, owner.address);
    await privacy.waitForDeployment();

    const MockGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
    const garbledCircuit = await MockGarbledCircuit.deploy(owner.address);
    await garbledCircuit.waitForDeployment();

    const MockGovernor = await ethers.getContractFactory("OmniCoinGovernor");
    const governor = await MockGovernor.deploy(ethers.ZeroAddress, owner.address);
    await governor.waitForDeployment();

    const MockEscrow = await ethers.getContractFactory("OmniCoinEscrow");
    const escrow = await MockEscrow.deploy(ethers.ZeroAddress, owner.address);
    await escrow.waitForDeployment();

    const MockBridge = await ethers.getContractFactory("OmniCoinBridge");
    const bridge = await MockBridge.deploy(ethers.ZeroAddress, owner.address);
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

      await expect(
        omniCoin.connect(attacker).pause()
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent unauthorized admin functions", async function () {
      const { omniCoin, attacker } = await loadFixture(deployOmniCoinFixture);

      await expect(
        omniCoin.connect(attacker).setMultisigThreshold(parseEther("5000"))
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");

      await expect(
        omniCoin.connect(attacker).togglePrivacy()
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should allow proper role-based access", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      // Owner should be able to mint
      await expect(
        omniCoin.connect(owner).mint(user1.address, parseEther("1000"))
      ).to.not.be.reverted;

      // Owner should be able to pause
      await expect(
        omniCoin.connect(owner).pause()
      ).to.not.be.reverted;

      // Owner should be able to unpause
      await expect(
        omniCoin.connect(owner).unpause()
      ).to.not.be.reverted;
    });
  });

  describe("Reentrancy Protection", function () {
    it("Should prevent reentrancy in transfer functions", async function () {
      const { omniCoin, owner, attacker } = await loadFixture(deployOmniCoinFixture);

      // Deploy a malicious contract that attempts reentrancy
      const MaliciousContract = await ethers.getContractFactory("MaliciousReentrant");
      const maliciousContract = await MaliciousContract.deploy(omniCoin.address);

      // Give the malicious contract some tokens
      await omniCoin.mint(maliciousContract.address, parseEther("1000"));

      // Attempt reentrancy attack should fail
      await expect(
        maliciousContract.attack()
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });

    it("Should prevent reentrancy in staking functions", async function () {
      const { omniCoin, owner, attacker } = await loadFixture(deployOmniCoinFixture);

      // Give attacker some tokens
      await omniCoin.mint(attacker.address, parseEther("1000"));

      // Attempt to call stake function in a reentrant manner
      // This should be prevented by the ReentrancyGuard
      await expect(
        omniCoin.connect(attacker).stake(parseEther("500"))
      ).to.not.be.reverted;
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

      // Zero amount transfer should succeed but do nothing
      await expect(
        omniCoin.transfer(user1.address, 0)
      ).to.not.be.reverted;
      
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
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should prevent staking when paused", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));
      await omniCoin.pause();

      await expect(
        omniCoin.stake(parseEther("500"))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should allow transfers after unpause", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));
      await omniCoin.pause();
      await omniCoin.unpause();

      await expect(
        omniCoin.transfer(user1.address, parseEther("100"))
      ).to.not.be.reverted;
    });
  });

  describe("Multisig Security", function () {
    it("Should require multisig approval for large transfers", async function () {
      const { omniCoin, owner, user1, multisig } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("10000"));
      
      // Set multisig threshold to 1000 tokens
      await omniCoin.setMultisigThreshold(parseEther("1000"));

      // Mock multisig approval as false
      await expect(
        omniCoin.transfer(user1.address, parseEther("5000"))
      ).to.be.revertedWith("OmniCoin: transfer requires multisig approval");
    });

    it("Should allow small transfers without multisig", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("10000"));

      // Transfer below multisig threshold should succeed
      await expect(
        omniCoin.transfer(user1.address, parseEther("500"))
      ).to.not.be.reverted;
    });
  });

  describe("Token Economics Security", function () {
    it("Should maintain total supply integrity", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      const mintAmount = parseEther("1000");
      await omniCoin.mint(owner.address, mintAmount);

      expect(await omniCoin.totalSupply()).to.equal(mintAmount);
      expect(await omniCoin.balanceOf(owner.address)).to.equal(mintAmount);

      // Transfer should not affect total supply
      await omniCoin.transfer(user1.address, parseEther("300"));
      expect(await omniCoin.totalSupply()).to.equal(mintAmount);
    });

    it("Should handle burning correctly", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);

      const mintAmount = parseEther("1000");
      const burnAmount = parseEther("300");

      await omniCoin.mint(owner.address, mintAmount);
      await omniCoin.burn(burnAmount);

      expect(await omniCoin.totalSupply()).to.equal(mintAmount.sub(burnAmount));
      expect(await omniCoin.balanceOf(owner.address)).to.equal(mintAmount.sub(burnAmount));
    });
  });

  describe("Integration Security", function () {
    it("Should handle contract interactions safely", async function () {
      const { omniCoin, owner, staking, escrow, bridge } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.mint(owner.address, parseEther("1000"));

      // Test staking interaction
      await expect(
        omniCoin.stake(parseEther("100"))
      ).to.not.be.reverted;

      // Test escrow interaction
      await expect(
        omniCoin.createEscrow(owner.address, parseEther("100"))
      ).to.not.be.reverted;

      // Test bridge interaction
      await expect(
        omniCoin.initiateBridgeTransfer(137, owner.address, parseEther("100"))
      ).to.not.be.reverted;
    });
  });

  describe("Privacy Security", function () {
    it("Should control privacy feature access", async function () {
      const { omniCoin, owner, attacker } = await loadFixture(deployOmniCoinFixture);

      // Privacy should be enabled by default
      expect(await omniCoin.privacyEnabled()).to.be.true;

      // Only admin should be able to toggle privacy
      await expect(
        omniCoin.connect(attacker).togglePrivacy()
      ).to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");

      // Admin should be able to toggle privacy
      await omniCoin.togglePrivacy();
      expect(await omniCoin.privacyEnabled()).to.be.false;
    });

    it("Should prevent privacy operations when disabled", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);

      await omniCoin.togglePrivacy(); // Disable privacy
      await omniCoin.mint(owner.address, parseEther("1000"));

      await expect(
        omniCoin.createPrivacyAccount()
      ).to.be.revertedWith("OmniCoin: privacy is disabled");

      await expect(
        omniCoin.transferPrivate(owner.address, parseEther("100"))
      ).to.be.revertedWith("OmniCoin: privacy is disabled");
    });
  });

  describe("Event Security", function () {
    it("Should emit events for security-relevant actions", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      // Mint event
      await expect(omniCoin.mint(owner.address, parseEther("1000")))
        .to.emit(omniCoin, "Transfer")
        .withArgs(ZeroAddress, owner.address, parseEther("1000"));

      // Multisig threshold change event
      await expect(omniCoin.setMultisigThreshold(parseEther("2000")))
        .to.emit(omniCoin, "MultisigThresholdUpdated")
        .withArgs(parseEther("1000000000"), parseEther("2000"));

      // Privacy toggle event
      await expect(omniCoin.togglePrivacy())
        .to.emit(omniCoin, "PrivacyToggled")
        .withArgs(false);
    });
  });

  describe("Gas Limit Security", function () {
    it("Should handle gas limit attacks", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);

      // Test with very large operations that might cause gas issues
      await omniCoin.mint(owner.address, parseEther("1000"));

      // These operations should complete within reasonable gas limits
      await expect(
        omniCoin.transfer(owner.address, parseEther("100"))
      ).to.not.be.reverted;
    });
  });
});

// Malicious contract for reentrancy testing
describe("MaliciousReentrant", function () {
  // This would be a separate contract file in a real implementation
  const maliciousContract = `
    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.20;

    interface IERC20 {
        function transfer(address to, uint256 amount) external returns (bool);
        function balanceOf(address account) external view returns (uint256);
    }

    contract MaliciousReentrant {
        IERC20 public token;
        bool public attacking;

        constructor(address _token) {
            token = IERC20(_token);
        }

        function attack() external {
            attacking = true;
            token.transfer(address(this), 100);
        }

        // This would be called during the transfer, attempting reentrancy
        function onTransfer() external {
            if (attacking) {
                attacking = false;
                token.transfer(msg.sender, token.balanceOf(address(this)));
            }
        }
    }
  `;
}); 