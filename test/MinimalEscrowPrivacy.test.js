const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("MinimalEscrow - Privacy Features", function () {
  // Test fixture to deploy contracts
  async function deployEscrowFixture() {
    const [owner, buyer, seller, arbitrator] = await ethers.getSigners();

    // Deploy test tokens
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const xom = await OmniCoin.deploy();
    await xom.initialize();

    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    const pxom = await PrivateOmniCoin.deploy();
    await pxom.initialize();

    // Create mock registry
    const mockRegistry = owner.address;

    // Deploy MinimalEscrow
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    const escrow = await MinimalEscrow.deploy(
      await xom.getAddress(),
      await pxom.getAddress(),
      mockRegistry
    );

    // Grant bridge role to escrow on pXOM
    const BRIDGE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BRIDGE_ROLE"));
    await pxom.grantRole(BRIDGE_ROLE, await escrow.getAddress());

    // Transfer tokens to buyer for testing
    await xom.transfer(buyer.address, ethers.parseEther("1000"));
    await pxom.mint(buyer.address, ethers.parseEther("1000"));

    return { escrow, xom, pxom, owner, buyer, seller, arbitrator };
  }

  describe("Deployment & Initialization", function () {
    it("Should set both token addresses correctly", async function () {
      const { escrow, xom, pxom } = await loadFixture(deployEscrowFixture);

      expect(await escrow.OMNI_COIN()).to.equal(await xom.getAddress());
      expect(await escrow.PRIVATE_OMNI_COIN()).to.equal(await pxom.getAddress());
    });

    it("Should detect privacy availability (false in Hardhat)", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      // Privacy should be disabled in Hardhat (not COTI network)
      expect(await escrow.privacyAvailable()).to.equal(false);
    });

    it("Should revert if XOM address is zero", async function () {
      const { pxom, owner } = await loadFixture(deployEscrowFixture);
      const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");

      await expect(
        MinimalEscrow.deploy(ethers.ZeroAddress, await pxom.getAddress(), owner.address)
      ).to.be.revertedWithCustomError(MinimalEscrow, "InvalidAddress");
    });

    it("Should revert if pXOM address is zero", async function () {
      const { xom, owner } = await loadFixture(deployEscrowFixture);
      const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");

      await expect(
        MinimalEscrow.deploy(await xom.getAddress(), ethers.ZeroAddress, owner.address)
      ).to.be.revertedWithCustomError(MinimalEscrow, "InvalidAddress");
    });

    it("Should revert if registry address is zero", async function () {
      const { xom, pxom } = await loadFixture(deployEscrowFixture);
      const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");

      await expect(
        MinimalEscrow.deploy(await xom.getAddress(), await pxom.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(MinimalEscrow, "InvalidAddress");
    });
  });

  describe("Privacy Not Available (Hardhat Environment)", function () {
    it("Should revert createPrivateEscrow when privacy not available", async function () {
      const { escrow, buyer, seller } = await loadFixture(deployEscrowFixture);

      // Attempt to create private escrow (will fail due to MPC unavailable)
      await expect(
        escrow.connect(buyer).createPrivateEscrow(
          seller.address,
          100, // This would be gtUint64 on COTI network
          3600
        )
      ).to.be.revertedWithCustomError(escrow, "PrivacyNotAvailable");
    });

    it("Should allow regular public escrow creation", async function () {
      const { escrow, xom, buyer, seller } = await loadFixture(deployEscrowFixture);

      const amount = ethers.parseEther("100");
      const duration = 86400; // 1 day

      // Approve tokens
      await xom.connect(buyer).approve(await escrow.getAddress(), amount);

      // Create public escrow
      await expect(
        escrow.connect(buyer).createEscrow(seller.address, amount, duration)
      ).to.emit(escrow, "EscrowCreated");

      // Verify escrow created
      const escrowData = await escrow.getEscrow(1);
      expect(escrowData.buyer).to.equal(buyer.address);
      expect(escrowData.seller).to.equal(seller.address);
      expect(escrowData.amount).to.equal(amount);
    });
  });

  describe("Privacy Function Signatures & Structure", function () {
    it("Should have createPrivateEscrow function", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      expect(escrow.createPrivateEscrow).to.be.a("function");
    });

    it("Should have releasePrivateFunds function", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      expect(escrow.releasePrivateFunds).to.be.a("function");
    });

    it("Should have refundPrivateBuyer function", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      expect(escrow.refundPrivateBuyer).to.be.a("function");
    });

    it("Should have votePrivate function", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      expect(escrow.votePrivate).to.be.a("function");
    });

    it("Should have getEncryptedAmount function", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      expect(escrow.getEncryptedAmount).to.be.a("function");
    });

    it("Should have privacyAvailable view function", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      expect(escrow.privacyAvailable).to.be.a("function");
    });
  });

  describe("State Variables", function () {
    it("Should track isPrivateEscrow flag", async function () {
      const { escrow, xom, buyer, seller } = await loadFixture(deployEscrowFixture);

      const amount = ethers.parseEther("100");

      // Create public escrow
      await xom.connect(buyer).approve(await escrow.getAddress(), amount);
      await escrow.connect(buyer).createEscrow(seller.address, amount, 86400);

      // Should be marked as non-private
      expect(await escrow.isPrivateEscrow(1)).to.equal(false);
    });
  });

  describe("Privacy Events", function () {
    it("Should have PrivateEscrowCreated event defined", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);
      const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");

      // Check if event exists in ABI
      const eventFragment = escrow.interface.getEvent("PrivateEscrowCreated");
      expect(eventFragment).to.not.be.undefined;
      expect(eventFragment.name).to.equal("PrivateEscrowCreated");
    });

    it("Should have PrivateEscrowResolved event defined", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      const eventFragment = escrow.interface.getEvent("PrivateEscrowResolved");
      expect(eventFragment).to.not.be.undefined;
      expect(eventFragment.name).to.equal("PrivateEscrowResolved");
    });

    it("Should have PrivateDisputeRaised event defined", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      const eventFragment = escrow.interface.getEvent("PrivateDisputeRaised");
      expect(eventFragment).to.not.be.undefined;
      expect(eventFragment.name).to.equal("PrivateDisputeRaised");
    });
  });

  describe("Custom Errors", function () {
    it("Should have PrivacyNotAvailable error", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      const errorFragment = escrow.interface.getError("PrivacyNotAvailable");
      expect(errorFragment).to.not.be.undefined;
    });

    it("Should have CannotMixPrivacyModes error", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      const errorFragment = escrow.interface.getError("CannotMixPrivacyModes");
      expect(errorFragment).to.not.be.undefined;
    });

    it("Should have AmountTooLarge error", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      const errorFragment = escrow.interface.getError("AmountTooLarge");
      expect(errorFragment).to.not.be.undefined;
    });
  });

  describe("Backward Compatibility", function () {
    it("Should maintain all public escrow functions", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      // Verify all original functions still exist
      expect(escrow.createEscrow).to.be.a("function");
      expect(escrow.releaseFunds).to.be.a("function");
      expect(escrow.refundBuyer).to.be.a("function");
      expect(escrow.commitDispute).to.be.a("function");
      expect(escrow.revealDispute).to.be.a("function");
      expect(escrow.vote).to.be.a("function");
      expect(escrow.getEscrow).to.be.a("function");
      expect(escrow.hasUserVoted).to.be.a("function");
    });

    it("Should allow public escrow flow to work unchanged", async function () {
      const { escrow, xom, buyer, seller } = await loadFixture(deployEscrowFixture);

      const amount = ethers.parseEther("100");

      // Create public escrow
      await xom.connect(buyer).approve(await escrow.getAddress(), amount);
      await escrow.connect(buyer).createEscrow(seller.address, amount, 86400);

      // Release funds (buyer agrees)
      await expect(
        escrow.connect(buyer).releaseFunds(1)
      ).to.emit(escrow, "EscrowResolved");

      // Verify resolution
      const escrowData = await escrow.getEscrow(1);
      expect(escrowData.resolved).to.equal(true);
      expect(escrowData.amount).to.equal(0);
    });
  });

  describe("Constants", function () {
    it("Should maintain existing constants", async function () {
      const { escrow } = await loadFixture(deployEscrowFixture);

      expect(await escrow.MAX_DURATION()).to.equal(2592000); // 30 days
      expect(await escrow.MIN_DURATION()).to.equal(3600); // 1 hour
      expect(await escrow.ARBITRATOR_DELAY()).to.equal(86400); // 24 hours
      expect(await escrow.DISPUTE_STAKE_BASIS()).to.equal(10); // 0.1%
      expect(await escrow.BASIS_POINTS()).to.equal(10000);
    });
  });
});

describe("MinimalEscrow - Privacy Integration Notes", function () {
  it("IMPORTANT: Full MPC testing requires COTI testnet deployment", function () {
    // This is a documentation test
    console.log(`

      ═══════════════════════════════════════════════════════════════
      COTI V2 MPC TESTING REQUIREMENTS
      ═══════════════════════════════════════════════════════════════

      The MinimalEscrow contract now supports privacy features via
      COTI V2 MPC (Multi-Party Computation), but full testing requires
      deployment to COTI networks where MPC precompiles are available.

      HARDHAT ENVIRONMENT:
      • Privacy features are DISABLED (block.chainid != COTI)
      • privacyAvailable() returns false
      • createPrivateEscrow() reverts with PrivacyNotAvailable
      • All public escrow functions work normally

      COTI NETWORKS (Full Privacy Testing):
      • COTI Devnet: Chain ID 13068200
      • COTI Testnet: Chain ID 7082
      • Privacy features AUTO-ENABLED on these networks
      • MPC operations (encrypt, decrypt, onBoard, offBoard) functional
      • Encrypted amounts remain private on-chain

      TO TEST PRIVACY FEATURES:
      1. Deploy contracts to COTI testnet
      2. Use COTI SDK for encrypted value creation
      3. Test createPrivateEscrow with gtUint64 encrypted amounts
      4. Verify private release/refund/voting flows
      5. Confirm amounts remain encrypted in events

      DEPLOYMENT COMMANDS:
      npx hardhat run scripts/deploy-coti-testnet.js --network cotiTestnet

      See FIX_PRIVACY.md for complete deployment instructions.

      ═══════════════════════════════════════════════════════════════
    `);
  });
});
