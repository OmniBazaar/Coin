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

      await expect(omniCoin.connect(attacker).pause())
        .to.be.revertedWithCustomError(omniCoin, "AccessControlUnauthorizedAccount");
    });

    it("Should allow owner to grant roles", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);

      const MINTER_ROLE = await omniCoin.MINTER_ROLE();
      await omniCoin.connect(owner).grantRole(MINTER_ROLE, await user1.getAddress());

      // Now user1 should be able to mint
      await expect(
        omniCoin.connect(user1).mint(await user1.getAddress(), parseEther("100"))
      ).to.not.be.reverted;
    });
  });

  describe("Transfer Security", function () {
    it("Should handle zero transfers correctly", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      
      // Zero transfer should succeed (as per ERC20 standard)
      await expect(
        omniCoin.transfer(await user1.getAddress(), 0)
      ).to.not.be.reverted;
    });

    it("Should prevent transfers to zero address", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      
      await expect(
        omniCoin.transfer(ZeroAddress, parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InvalidReceiver");
    });

    it("Should not allow transfers when paused", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      await omniCoin.pause();
      
      await expect(
        omniCoin.transfer(await user1.getAddress(), parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
      
      // Should work after unpausing
      await omniCoin.unpause();
      await expect(
        omniCoin.transfer(await user1.getAddress(), parseEther("100"))
      ).to.not.be.reverted;
    });
  });

  describe("Approval Security", function () {
    it("Should handle approval edge cases", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Approve to zero address should fail
      await expect(
        omniCoin.approve(ZeroAddress, parseEther("100"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InvalidSpender");
      
      // Self-approval should work
      await expect(
        omniCoin.approve(await owner.getAddress(), parseEther("100"))
      ).to.not.be.reverted;
    });

    it("Should handle transferFrom correctly", async function () {
      const { omniCoin, owner, user1, user2 } = await loadFixture(deployOmniCoinFixture);
      
      await omniCoin.mint(await owner.getAddress(), parseEther("1000"));
      
      // Approve user1 to spend 100 tokens
      await omniCoin.approve(await user1.getAddress(), parseEther("100"));
      
      // user1 transfers from owner to user2
      await expect(
        omniCoin.connect(user1).transferFrom(
          await owner.getAddress(),
          await user2.getAddress(),
          parseEther("50")
        )
      ).to.not.be.reverted;
      
      // Check remaining allowance
      expect(await omniCoin.allowance(await owner.getAddress(), await user1.getAddress()))
        .to.equal(parseEther("50"));
      
      // Exceeding allowance should fail
      await expect(
        omniCoin.connect(user1).transferFrom(
          await owner.getAddress(),
          await user2.getAddress(),
          parseEther("51")
        )
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientAllowance");
    });
  });

  describe("Supply Security", function () {
    it("Should correctly handle burning", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const mintAmount = parseEther("1000");
      await omniCoin.mint(await user1.getAddress(), mintAmount);
      
      // User can burn their own tokens
      await expect(
        omniCoin.connect(user1).burn(parseEther("100"))
      ).to.not.be.reverted;
      
      expect(await omniCoin.balanceOf(await user1.getAddress()))
        .to.equal(parseEther("900"));
      
      // Cannot burn more than balance
      await expect(
        omniCoin.connect(user1).burn(parseEther("1000"))
      ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientBalance");
    });

    it("Should correctly handle burnFrom", async function () {
      const { omniCoin, owner, user1, user2 } = await loadFixture(deployOmniCoinFixture);
      
      // Grant BURNER_ROLE to user1
      const BURNER_ROLE = await omniCoin.BURNER_ROLE();
      await omniCoin.grantRole(BURNER_ROLE, await user1.getAddress());
      
      // Mint to user2
      await omniCoin.mint(await user2.getAddress(), parseEther("1000"));
      
      // user2 approves user1 to burn
      await omniCoin.connect(user2).approve(await user1.getAddress(), parseEther("500"));
      
      // user1 burns from user2's balance
      await expect(
        omniCoin.connect(user1).burnFrom(await user2.getAddress(), parseEther("200"))
      ).to.not.be.reverted;
      
      expect(await omniCoin.balanceOf(await user2.getAddress()))
        .to.equal(parseEther("800"));
      
      // Check remaining allowance
      expect(await omniCoin.allowance(await user2.getAddress(), await user1.getAddress()))
        .to.equal(parseEther("300"));
    });
  });

  describe("Permit Functionality", function () {
    it("Should handle permit nonce correctly", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      const initialNonce = await omniCoin.nonces(await owner.getAddress());
      expect(initialNonce).to.equal(0);
      
      const value = parseEther("100");
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
        nonce: initialNonce,
        deadline: deadline
      };
      
      const signature = await owner.signTypedData(domain, types, message);
      const sig = ethers.Signature.from(signature);
      
      // Use permit
      await omniCoin.permit(
        await owner.getAddress(),
        await user1.getAddress(),
        value,
        deadline,
        sig.v,
        sig.r,
        sig.s
      );
      
      // Nonce should increment
      expect(await omniCoin.nonces(await owner.getAddress())).to.equal(1);
      
      // Trying to reuse the same signature should fail
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
      ).to.be.revertedWithCustomError(omniCoin, "ERC2612InvalidSigner");
    });
  });

  describe("Edge Cases", function () {
    it("Should handle max uint256 transfers correctly", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployOmniCoinFixture);
      
      // Mint close to max supply
      const amount = parseEther("1000000"); // 1M tokens
      await omniCoin.mint(await owner.getAddress(), amount);
      
      // Transfer all
      await expect(
        omniCoin.transfer(await user1.getAddress(), amount)
      ).to.not.be.reverted;
      
      expect(await omniCoin.balanceOf(await user1.getAddress())).to.equal(amount);
      expect(await omniCoin.balanceOf(await owner.getAddress())).to.equal(0);
    });

    it("Should handle multiple pauses and unpauses", async function () {
      const { omniCoin, owner } = await loadFixture(deployOmniCoinFixture);
      
      // Initial state should be unpaused
      expect(await omniCoin.paused()).to.be.false;
      
      // Pause
      await omniCoin.pause();
      expect(await omniCoin.paused()).to.be.true;
      
      // Cannot pause again
      await expect(omniCoin.pause())
        .to.be.revertedWithCustomError(omniCoin, "EnforcedPause");
      
      // Unpause
      await omniCoin.unpause();
      expect(await omniCoin.paused()).to.be.false;
      
      // Cannot unpause again
      await expect(omniCoin.unpause())
        .to.be.revertedWithCustomError(omniCoin, "ExpectedPause");
    });
  });
});