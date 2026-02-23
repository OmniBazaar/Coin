const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniNFTRoyalty Test Suite
 * @notice Tests for the standalone ERC-2981 royalty registry.
 * @dev After the H-01 audit fix, first-time collection registration
 *      by non-admin callers requires ownership verification via
 *      IOwnable(collection).owner(). EOA addresses cannot be used as
 *      collection parameters. Instead, we deploy Ownable contracts
 *      (OmniNFTRoyalty itself is Ownable) and use them as collections.
 *      The admin (contract owner) can bypass verification.
 */
describe("OmniNFTRoyalty", function () {
  let royalty;
  let owner, alice, bob, carol;

  // Ownable contracts deployed per-signer to use as collection addresses
  let aliceCollection, bobCollection, carolCollection;

  /**
   * @notice Deploys an OmniNFTRoyalty from a given signer.
   *         The deployer becomes the Ownable owner, satisfying H-01 checks.
   */
  async function deployOwnableCollection(signer) {
    const Factory = await ethers.getContractFactory("OmniNFTRoyalty", signer);
    const c = await Factory.deploy();
    await c.waitForDeployment();
    return c;
  }

  /** Deploy a fresh OmniNFTRoyalty before every test. */
  beforeEach(async function () {
    [owner, alice, bob, carol] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("OmniNFTRoyalty");
    royalty = await Factory.deploy();
    await royalty.waitForDeployment();

    // Deploy Ownable contracts so each signer "owns" a collection address
    aliceCollection = await deployOwnableCollection(alice);
    bobCollection = await deployOwnableCollection(bob);
    carolCollection = await deployOwnableCollection(carol);
  });

  // ── Deployment ──────────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("Should set deployer as contract owner", async function () {
      expect(await royalty.owner()).to.equal(owner.address);
    });

    it("Should expose MAX_ROYALTY_BPS as 2500", async function () {
      expect(await royalty.MAX_ROYALTY_BPS()).to.equal(2500);
    });

    it("Should start with zero registered collections", async function () {
      expect(await royalty.totalRegistered()).to.equal(0);
    });
  });

  // ── setRoyalty ──────────────────────────────────────────────────────────

  describe("setRoyalty", function () {
    it("Should register royalty with correct values", async function () {
      const collectionAddr = await aliceCollection.getAddress();
      const recipient = bob.address;
      const bps = 500; // 5%

      // Alice owns aliceCollection so verification passes
      await royalty.connect(alice).setRoyalty(collectionAddr, recipient, bps);

      const info = await royalty.royalties(collectionAddr);
      expect(info.recipient).to.equal(recipient);
      expect(info.royaltyBps).to.equal(bps);
      expect(info.registeredOwner).to.equal(alice.address);
    });

    it("Should emit RoyaltySet event with correct args", async function () {
      const collectionAddr = await aliceCollection.getAddress();
      const recipient = bob.address;
      const bps = 1000;

      await expect(royalty.connect(alice).setRoyalty(collectionAddr, recipient, bps))
        .to.emit(royalty, "RoyaltySet")
        .withArgs(collectionAddr, recipient, bps, alice.address);
    });

    it("Should make first caller the registeredOwner", async function () {
      const collectionAddr = await carolCollection.getAddress();

      // Carol owns carolCollection so verification passes
      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 250);

      const info = await royalty.royalties(collectionAddr);
      expect(info.registeredOwner).to.equal(carol.address);
    });

    it("Should allow the registeredOwner to update royalty", async function () {
      const collectionAddr = await carolCollection.getAddress();

      // Carol registers (she owns the collection)
      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 250);
      // Carol updates (she is the registeredOwner)
      await royalty.connect(carol).setRoyalty(collectionAddr, carol.address, 500);

      const info = await royalty.royalties(collectionAddr);
      expect(info.recipient).to.equal(carol.address);
      expect(info.royaltyBps).to.equal(500);
      // Owner unchanged
      expect(info.registeredOwner).to.equal(carol.address);
    });

    it("Should allow admin (contract owner) to register any collection", async function () {
      // Admin can register without ownership verification
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(owner).setRoyalty(collectionAddr, owner.address, 1500);

      const info = await royalty.royalties(collectionAddr);
      expect(info.recipient).to.equal(owner.address);
      expect(info.royaltyBps).to.equal(1500);
      expect(info.registeredOwner).to.equal(owner.address);
    });

    it("Should allow admin (contract owner) to update any collection", async function () {
      const collectionAddr = await carolCollection.getAddress();

      // Carol registers
      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 250);
      // Owner (admin) updates
      await royalty.connect(owner).setRoyalty(collectionAddr, owner.address, 1500);

      const info = await royalty.royalties(collectionAddr);
      expect(info.recipient).to.equal(owner.address);
      expect(info.royaltyBps).to.equal(1500);
      // registeredOwner is still Carol (admin update does not change it)
      expect(info.registeredOwner).to.equal(carol.address);
    });

    it("Should revert with RoyaltyTooHigh when bps > 2500", async function () {
      const collectionAddr = await aliceCollection.getAddress();
      await expect(
        royalty.connect(alice).setRoyalty(collectionAddr, carol.address, 2501)
      ).to.be.revertedWithCustomError(royalty, "RoyaltyTooHigh");
    });

    it("Should accept exactly MAX_ROYALTY_BPS (2500)", async function () {
      const collectionAddr = await aliceCollection.getAddress();
      await expect(
        royalty.connect(alice).setRoyalty(collectionAddr, carol.address, 2500)
      ).to.not.be.reverted;
    });

    it("Should revert with InvalidRecipient when recipient is zero address", async function () {
      const collectionAddr = await aliceCollection.getAddress();
      await expect(
        royalty.connect(alice).setRoyalty(collectionAddr, ethers.ZeroAddress, 500)
      ).to.be.revertedWithCustomError(royalty, "InvalidRecipient");
    });

    it("Should revert with InvalidCollection when collection is zero address", async function () {
      await expect(
        royalty.connect(alice).setRoyalty(ethers.ZeroAddress, bob.address, 500)
      ).to.be.revertedWithCustomError(royalty, "InvalidCollection");
    });

    it("Should revert with NotCollectionOwner when non-owner, non-admin updates", async function () {
      const collectionAddr = await carolCollection.getAddress();

      // Carol registers (she owns the collection)
      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 250);
      // Bob (not registeredOwner, not admin) tries to update
      await expect(
        royalty.connect(bob).setRoyalty(collectionAddr, bob.address, 1000)
      ).to.be.revertedWithCustomError(royalty, "NotCollectionOwner");
    });

    it("Should revert with OwnershipVerificationFailed when non-owner registers", async function () {
      // aliceCollection is owned by alice; bob tries to register it
      const collectionAddr = await aliceCollection.getAddress();
      await expect(
        royalty.connect(bob).setRoyalty(collectionAddr, bob.address, 500)
      ).to.be.revertedWithCustomError(royalty, "OwnershipVerificationFailed");
    });

    it("Should revert for EOA collection addresses (no code)", async function () {
      // EOAs have no code, so IOwnable(collection).owner() fails.
      // The revert may or may not carry a custom error depending on
      // the EVM implementation when calling an address with no code.
      await expect(
        royalty.connect(alice).setRoyalty(alice.address, bob.address, 500)
      ).to.be.reverted;
    });
  });

  // ── transferCollectionOwnership ─────────────────────────────────────────

  describe("transferCollectionOwnership", function () {
    it("Should transfer ownership and emit CollectionOwnerUpdated", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);

      await expect(
        royalty.connect(carol).transferCollectionOwnership(collectionAddr, bob.address)
      )
        .to.emit(royalty, "CollectionOwnerUpdated")
        .withArgs(collectionAddr, carol.address, bob.address);

      const info = await royalty.royalties(collectionAddr);
      expect(info.registeredOwner).to.equal(bob.address);
    });

    it("Should allow new owner to update royalty after transfer", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);
      await royalty.connect(carol).transferCollectionOwnership(collectionAddr, bob.address);

      // Bob is now the registeredOwner and can update (already registered, no ownership check)
      await royalty.connect(bob).setRoyalty(collectionAddr, carol.address, 1000);

      const info = await royalty.royalties(collectionAddr);
      expect(info.recipient).to.equal(carol.address);
      expect(info.royaltyBps).to.equal(1000);
    });

    it("Should allow admin to transfer ownership of any collection", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);

      await expect(
        royalty.connect(owner).transferCollectionOwnership(collectionAddr, bob.address)
      )
        .to.emit(royalty, "CollectionOwnerUpdated")
        .withArgs(collectionAddr, carol.address, bob.address);
    });

    it("Should revert with NotCollectionOwner when called by non-owner, non-admin", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);

      await expect(
        royalty.connect(bob).transferCollectionOwnership(collectionAddr, carol.address)
      ).to.be.revertedWithCustomError(royalty, "NotCollectionOwner");
    });

    it("Should revert with InvalidNewOwner when newOwner is zero address", async function () {
      const collectionAddr = await carolCollection.getAddress();
      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);

      await expect(
        royalty.connect(carol).transferCollectionOwnership(collectionAddr, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(royalty, "InvalidNewOwner");
    });
  });

  // ── royaltyInfo ─────────────────────────────────────────────────────────

  describe("royaltyInfo", function () {
    it("Should return correct recipient and royalty amount for a registered collection", async function () {
      const collectionAddr = await carolCollection.getAddress();
      const recipient = bob.address;
      const bps = 1000; // 10%
      const salePrice = ethers.parseEther("2"); // 2 ETH

      // carolCollection has code but does not implement ERC-2981,
      // so the fallback to registry will be used after try/catch
      await royalty.connect(carol).setRoyalty(collectionAddr, recipient, bps);

      const [receiver, amount] = await royalty.royaltyInfo(collectionAddr, 1, salePrice);

      expect(receiver).to.equal(recipient);
      // 2 ETH * 1000 / 10000 = 0.2 ETH
      expect(amount).to.equal(ethers.parseEther("0.2"));
    });

    it("Should return (address(0), 0) when collection is not registered", async function () {
      const collectionAddr = await carolCollection.getAddress();
      const [receiver, amount] = await royalty.royaltyInfo(collectionAddr, 1, ethers.parseEther("1"));

      expect(receiver).to.equal(ethers.ZeroAddress);
      expect(amount).to.equal(0);
    });

    it("Should calculate royalty correctly at MAX_ROYALTY_BPS boundary", async function () {
      const collectionAddr = await carolCollection.getAddress();
      const salePrice = ethers.parseEther("10");

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 2500);

      const [receiver, amount] = await royalty.royaltyInfo(collectionAddr, 42, salePrice);

      expect(receiver).to.equal(bob.address);
      // 10 ETH * 2500 / 10000 = 2.5 ETH
      expect(amount).to.equal(ethers.parseEther("2.5"));
    });

    it("Should handle zero sale price correctly", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 1000);

      const [receiver, amount] = await royalty.royaltyInfo(collectionAddr, 1, 0);

      expect(receiver).to.equal(bob.address);
      expect(amount).to.equal(0);
    });

    it("Should return (address(0), 0) when royaltyBps is zero via admin registration", async function () {
      const collectionAddr = await carolCollection.getAddress();

      // Admin registers with 0 bps (allowed by contract)
      await royalty.connect(owner).setRoyalty(collectionAddr, bob.address, 0);

      // Contract checks: if recipient == 0 || royaltyBps == 0 => return (0, 0)
      const [receiver, amount] = await royalty.royaltyInfo(collectionAddr, 1, ethers.parseEther("1"));

      expect(receiver).to.equal(ethers.ZeroAddress);
      expect(amount).to.equal(0);
    });
  });

  // ── totalRegistered ─────────────────────────────────────────────────────

  describe("totalRegistered", function () {
    it("Should return correct count after registrations", async function () {
      expect(await royalty.totalRegistered()).to.equal(0);

      // Register three distinct collections
      const aliceAddr = await aliceCollection.getAddress();
      const bobAddr = await bobCollection.getAddress();
      const carolAddr = await carolCollection.getAddress();

      await royalty.connect(alice).setRoyalty(aliceAddr, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(1);

      await royalty.connect(bob).setRoyalty(bobAddr, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(2);

      await royalty.connect(carol).setRoyalty(carolAddr, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(3);
    });

    it("Should not increment count when updating an existing collection", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(1);

      // Update (same collection) should NOT increase count
      await royalty.connect(carol).setRoyalty(collectionAddr, alice.address, 1000);
      expect(await royalty.totalRegistered()).to.equal(1);
    });
  });

  // ── isRegistered & registeredCollections ────────────────────────────────

  describe("isRegistered and registeredCollections", function () {
    it("Should track registration status correctly", async function () {
      const collectionAddr = await carolCollection.getAddress();

      expect(await royalty.isRegistered(collectionAddr)).to.equal(false);

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);

      expect(await royalty.isRegistered(collectionAddr)).to.equal(true);
    });

    it("Should store collection in registeredCollections array", async function () {
      const collectionAddr = await carolCollection.getAddress();

      await royalty.connect(carol).setRoyalty(collectionAddr, bob.address, 500);

      expect(await royalty.registeredCollections(0)).to.equal(collectionAddr);
    });
  });
});
