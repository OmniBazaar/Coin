const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniNFTRoyalty", function () {
  let royalty;
  let owner, alice, bob, carol;

  /** Deploy a fresh OmniNFTRoyalty before every test. */
  beforeEach(async function () {
    [owner, alice, bob, carol] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("OmniNFTRoyalty");
    royalty = await Factory.deploy();
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
      const collection = alice.address; // EOA used as collection address
      const recipient = bob.address;
      const bps = 500; // 5%

      await royalty.connect(alice).setRoyalty(collection, recipient, bps);

      const info = await royalty.royalties(collection);
      expect(info.recipient).to.equal(recipient);
      expect(info.royaltyBps).to.equal(bps);
      expect(info.registeredOwner).to.equal(alice.address);
    });

    it("Should emit RoyaltySet event with correct args", async function () {
      const collection = alice.address;
      const recipient = bob.address;
      const bps = 1000;

      await expect(royalty.connect(alice).setRoyalty(collection, recipient, bps))
        .to.emit(royalty, "RoyaltySet")
        .withArgs(collection, recipient, bps, alice.address);
    });

    it("Should make first caller the registeredOwner", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 250);

      const info = await royalty.royalties(collection);
      expect(info.registeredOwner).to.equal(alice.address);
    });

    it("Should allow the registeredOwner to update royalty", async function () {
      const collection = carol.address;

      // Alice registers
      await royalty.connect(alice).setRoyalty(collection, bob.address, 250);
      // Alice updates
      await royalty.connect(alice).setRoyalty(collection, carol.address, 500);

      const info = await royalty.royalties(collection);
      expect(info.recipient).to.equal(carol.address);
      expect(info.royaltyBps).to.equal(500);
      // Owner unchanged
      expect(info.registeredOwner).to.equal(alice.address);
    });

    it("Should allow admin (contract owner) to update any collection", async function () {
      const collection = carol.address;

      // Alice registers
      await royalty.connect(alice).setRoyalty(collection, bob.address, 250);
      // Owner (admin) updates
      await royalty.connect(owner).setRoyalty(collection, owner.address, 1500);

      const info = await royalty.royalties(collection);
      expect(info.recipient).to.equal(owner.address);
      expect(info.royaltyBps).to.equal(1500);
      // registeredOwner is still Alice (admin update does not change it)
      expect(info.registeredOwner).to.equal(alice.address);
    });

    it("Should revert with RoyaltyTooHigh when bps > 2500", async function () {
      await expect(
        royalty.connect(alice).setRoyalty(bob.address, carol.address, 2501)
      ).to.be.revertedWithCustomError(royalty, "RoyaltyTooHigh");
    });

    it("Should accept exactly MAX_ROYALTY_BPS (2500)", async function () {
      await expect(
        royalty.connect(alice).setRoyalty(bob.address, carol.address, 2500)
      ).to.not.be.reverted;
    });

    it("Should revert with InvalidRecipient when recipient is zero address", async function () {
      await expect(
        royalty.connect(alice).setRoyalty(bob.address, ethers.ZeroAddress, 500)
      ).to.be.revertedWithCustomError(royalty, "InvalidRecipient");
    });

    it("Should revert with NotCollectionOwner when non-owner, non-admin updates", async function () {
      const collection = carol.address;

      // Alice registers
      await royalty.connect(alice).setRoyalty(collection, bob.address, 250);
      // Bob (not registeredOwner, not admin) tries to update
      await expect(
        royalty.connect(bob).setRoyalty(collection, bob.address, 1000)
      ).to.be.revertedWithCustomError(royalty, "NotCollectionOwner");
    });
  });

  // ── transferCollectionOwnership ─────────────────────────────────────────

  describe("transferCollectionOwnership", function () {
    it("Should transfer ownership and emit CollectionOwnerUpdated", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);

      await expect(
        royalty.connect(alice).transferCollectionOwnership(collection, bob.address)
      )
        .to.emit(royalty, "CollectionOwnerUpdated")
        .withArgs(collection, alice.address, bob.address);

      const info = await royalty.royalties(collection);
      expect(info.registeredOwner).to.equal(bob.address);
    });

    it("Should allow new owner to update royalty after transfer", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);
      await royalty.connect(alice).transferCollectionOwnership(collection, bob.address);

      // Bob is now the registeredOwner and can update
      await royalty.connect(bob).setRoyalty(collection, carol.address, 1000);

      const info = await royalty.royalties(collection);
      expect(info.recipient).to.equal(carol.address);
      expect(info.royaltyBps).to.equal(1000);
    });

    it("Should allow admin to transfer ownership of any collection", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);

      await expect(
        royalty.connect(owner).transferCollectionOwnership(collection, bob.address)
      )
        .to.emit(royalty, "CollectionOwnerUpdated")
        .withArgs(collection, alice.address, bob.address);
    });

    it("Should revert with NotCollectionOwner when called by non-owner, non-admin", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);

      await expect(
        royalty.connect(bob).transferCollectionOwnership(collection, carol.address)
      ).to.be.revertedWithCustomError(royalty, "NotCollectionOwner");
    });
  });

  // ── royaltyInfo ─────────────────────────────────────────────────────────

  describe("royaltyInfo", function () {
    it("Should return correct recipient and royalty amount for a registered collection", async function () {
      // Use an EOA as collection so extcodesize == 0 => registry-only lookup
      const collection = carol.address;
      const recipient = bob.address;
      const bps = 1000; // 10%
      const salePrice = ethers.parseEther("2"); // 2 ETH

      await royalty.connect(alice).setRoyalty(collection, recipient, bps);

      const [receiver, amount] = await royalty.royaltyInfo(collection, 1, salePrice);

      expect(receiver).to.equal(recipient);
      // 2 ETH * 1000 / 10000 = 0.2 ETH
      expect(amount).to.equal(ethers.parseEther("0.2"));
    });

    it("Should return (address(0), 0) when collection is not registered", async function () {
      const [receiver, amount] = await royalty.royaltyInfo(carol.address, 1, ethers.parseEther("1"));

      expect(receiver).to.equal(ethers.ZeroAddress);
      expect(amount).to.equal(0);
    });

    it("Should return (address(0), 0) when royaltyBps is zero", async function () {
      const collection = carol.address;

      // Register with 0 bps
      await royalty.connect(alice).setRoyalty(collection, bob.address, 0);

      // Contract checks: if recipient == 0 || royaltyBps == 0 => return (0, 0)
      // Here recipient is non-zero but bps is 0 => still returns (0, 0)
      const [receiver, amount] = await royalty.royaltyInfo(collection, 1, ethers.parseEther("1"));

      expect(receiver).to.equal(ethers.ZeroAddress);
      expect(amount).to.equal(0);
    });

    it("Should calculate royalty correctly at MAX_ROYALTY_BPS boundary", async function () {
      const collection = carol.address;
      const salePrice = ethers.parseEther("10");

      await royalty.connect(alice).setRoyalty(collection, bob.address, 2500);

      const [receiver, amount] = await royalty.royaltyInfo(collection, 42, salePrice);

      expect(receiver).to.equal(bob.address);
      // 10 ETH * 2500 / 10000 = 2.5 ETH
      expect(amount).to.equal(ethers.parseEther("2.5"));
    });

    it("Should handle zero sale price correctly", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 1000);

      const [receiver, amount] = await royalty.royaltyInfo(collection, 1, 0);

      expect(receiver).to.equal(bob.address);
      expect(amount).to.equal(0);
    });
  });

  // ── totalRegistered ─────────────────────────────────────────────────────

  describe("totalRegistered", function () {
    it("Should return correct count after registrations", async function () {
      expect(await royalty.totalRegistered()).to.equal(0);

      // Register three distinct collections (using EOA addresses)
      await royalty.connect(alice).setRoyalty(alice.address, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(1);

      await royalty.connect(alice).setRoyalty(bob.address, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(2);

      await royalty.connect(alice).setRoyalty(carol.address, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(3);
    });

    it("Should not increment count when updating an existing collection", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);
      expect(await royalty.totalRegistered()).to.equal(1);

      // Update (same collection) should NOT increase count
      await royalty.connect(alice).setRoyalty(collection, alice.address, 1000);
      expect(await royalty.totalRegistered()).to.equal(1);
    });
  });

  // ── isRegistered & registeredCollections ────────────────────────────────

  describe("isRegistered and registeredCollections", function () {
    it("Should track registration status correctly", async function () {
      const collection = carol.address;

      expect(await royalty.isRegistered(collection)).to.equal(false);

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);

      expect(await royalty.isRegistered(collection)).to.equal(true);
    });

    it("Should store collection in registeredCollections array", async function () {
      const collection = carol.address;

      await royalty.connect(alice).setRoyalty(collection, bob.address, 500);

      expect(await royalty.registeredCollections(0)).to.equal(collection);
    });
  });
});
