const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// Helper function for ethers v6 compatibility
const parseEther = ethers.parseEther;
const ZeroAddress = ethers.ZeroAddress;

describe("OmniCoin Security Tests", function () {
  async function deployOmniCoinFixture() {
    const [owner, attacker, user1, user2] = await ethers.getSigners();

    // Deploy actual OmniCoinRegistry
    const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await OmniCoinRegistry.deploy(await owner.getAddress());
    await registry.waitForDeployment();

    // Deploy actual OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy(await registry.getAddress());
    await omniCoin.waitForDeployment();

    // Set up registry
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
      await omniCoin.getAddress()
    );

    return { omniCoin, owner, attacker, user1, user2, registry };
  }

  describe("Access Control Security", function () {
    it("Should prevent unauthorized minting", async function () {
      const { omniCoin, attacker } = await loadFixture(deployOmniCoinFixture);

      await expect(
        omniCoin.connect(attacker).mint(await attacker.getAddress(), parseEther("1000"))
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

    it("Should allow proper role-based access", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      // Owner should be able to mint
      await expect(
        omniCoin.connect(owner).mint(await user1.getAddress(), parseEther("1000"))
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

  describe("Transfer Security", function () {
    it("Should prevent transfers to zero address", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      
      await expect(
        omniCoin.transfer(ZeroAddress, parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InvalidReceiver");
    });

    it("Should prevent transfers from zero address", async function () {
      const { omniCoin, user1 } = await loadFixture(deployOmniCoinFixture);
      
      await expect(
        omniCoin.transferFrom(ZeroAddress, await user1.getAddress(), parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InvalidApprover");
    });

    it("Should not allow transfers when paused", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      await omniCoin.pause();
      
      await expect(
        omniCoin.transfer(await user1.getAddress(), parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
    });
  });

  describe("Approval Security", function () {
    it("Should prevent integer overflow in approvals", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const maxUint256 = ethers.MaxUint256;
      
      // Approve max value should work
      await expect(
        omniCoin.approve(await user1.getAddress(), maxUint256)
      ).to.not.be.reverted;
      
      // Check approval was set correctly
      expect(await omniCoin.allowance(await owner.getAddress(), await user1.getAddress()))
        .to.equal(maxUint256);
    });

    it("Should handle approval race conditions", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      
      // Set initial approval
      await omniCoin.approve(await user1.getAddress(), parseEther("100"));
      
      // Change approval directly (potential race condition)
      await omniCoin.approve(await user1.getAddress(), parseEther("200"));
      
      // Check final approval
      expect(await omniCoin.allowance(await owner.getAddress(), await user1.getAddress()))
        .to.equal(parseEther("200"));
    });
  });

  describe("Supply Security", function () {
    it("Should enforce max supply limits", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);
      
      const MAX_SUPPLY = await omniCoin.MAX_SUPPLY();
      
      // Try to mint more than max supply
      await expect(
        omniCoin.mint(await owner.getAddress(), MAX_SUPPLY + 1n)
      ).to.be.revertedWithCustomError(omniCoin, "ExceedsMaxSupply");
    });

    it("Should track total supply correctly", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const mintAmount = parseEther("1000");
      await omniCoin.mint(await user1.getAddress(), mintAmount);
      
      expect(await omniCoin.totalSupply()).to.equal(mintAmount);
      
      // Burn some tokens
      await omniCoin.connect(user1).burn(parseEther("100"));
      
      expect(await omniCoin.totalSupply()).to.equal(parseEther("900"));
    });
  });

  describe("Permit Signature Security", function () {
    it("Should validate permit signatures correctly", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const value = parseEther("100");
      const nonce = await omniCoin.nonces(await owner.getAddress());
      const deadline = ethers.MaxUint256;
      
      // Create permit signature
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
      
      const message = {
        owner: await owner.getAddress(),
        spender: await user1.getAddress(),
        value: value,
        nonce: nonce,
        deadline: deadline
      };
      
      const signature = await owner.signTypedData(domain, types, message);
      const sig = ethers.Signature.from(signature);
      
      // Use permit
      await expect(
        omniCoin.permit(
          await owner.getAddress(),
          await user1.getAddress(),
          value,
          deadline,
          sig.v,
          sig.r,
          sig.s
        )
      ).to.not.be.reverted;
      
      // Check allowance was set
      expect(await omniCoin.allowance(await owner.getAddress(), await user1.getAddress()))
        .to.equal(value);
    });

    it("Should reject expired permits", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const value = parseEther("100");
      const nonce = await omniCoin.nonces(await owner.getAddress());
      const deadline = 1; // Already expired
      
      // Create permit signature
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
      
      const message = {
        owner: await owner.getAddress(),
        spender: await user1.getAddress(),
        value: value,
        nonce: nonce,
        deadline: deadline
      };
      
      const signature = await owner.signTypedData(domain, types, message);
      const sig = ethers.Signature.from(signature);
      
      // Use expired permit
      await expect(
        omniCoin.permit(
          await owner.getAddress(),
          await user1.getAddress(),
          value,
          deadline,
          sig.v,
          sig.r,
          sig.s
        )
      ).to.be.revertedWithCustomError(omniCoin, "ERC2612ExpiredSignature");
    });
  });
});