const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniNFTFactory", function () {
  let factory, impl;
  let owner, creator1, creator2, user1;

  beforeEach(async function () {
    [owner, creator1, creator2, user1] = await ethers.getSigners();

    const Collection = await ethers.getContractFactory("OmniNFTCollection");
    impl = await Collection.deploy();

    const Factory = await ethers.getContractFactory("OmniNFTFactory");
    factory = await Factory.deploy(await impl.getAddress());
  });

  describe("Deployment", function () {
    it("Should set correct implementation", async function () {
      expect(await factory.implementation()).to.equal(await impl.getAddress());
    });

    it("Should set default platform fee to 2.5%", async function () {
      expect(await factory.platformFeeBps()).to.equal(250);
    });

    it("Should set deployer as owner", async function () {
      expect(await factory.owner()).to.equal(owner.address);
    });

    it("Should reject zero implementation address", async function () {
      const Factory = await ethers.getContractFactory("OmniNFTFactory");
      await expect(
        Factory.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(factory, "InvalidImplementation");
    });
  });

  describe("Collection Creation", function () {
    it("Should create a collection", async function () {
      const tx = await factory.connect(creator1).createCollection(
        "Test Collection", "TEST", 1000, 500, creator1.address, "ipfs://hidden"
      );
      const receipt = await tx.wait();

      expect(await factory.totalCollections()).to.equal(1);

      // Verify event
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      expect(event).to.not.be.undefined;
      expect(event.args.creator).to.equal(creator1.address);
      expect(event.args.name).to.equal("Test Collection");
      expect(event.args.symbol).to.equal("TEST");
      expect(event.args.maxSupply).to.equal(1000);
      expect(event.args.royaltyBps).to.equal(500);
    });

    it("Should track collections per creator", async function () {
      await factory.connect(creator1).createCollection(
        "C1", "C1", 100, 0, creator1.address, ""
      );
      await factory.connect(creator1).createCollection(
        "C2", "C2", 200, 0, creator1.address, ""
      );
      await factory.connect(creator2).createCollection(
        "C3", "C3", 300, 0, creator2.address, ""
      );

      expect(await factory.creatorCollectionCount(creator1.address)).to.equal(2);
      expect(await factory.creatorCollectionCount(creator2.address)).to.equal(1);
      expect(await factory.totalCollections()).to.equal(3);
    });

    it("Should mark clones as factory collections", async function () {
      const tx = await factory.connect(creator1).createCollection(
        "Test", "T", 50, 0, creator1.address, ""
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr = event.args[0];
      expect(await factory.isFactoryCollection(addr)).to.equal(true);
      expect(await factory.isFactoryCollection(owner.address)).to.equal(false);
    });

    it("Should reject zero max supply", async function () {
      await expect(
        factory.connect(creator1).createCollection(
          "Bad", "BAD", 0, 0, creator1.address, ""
        )
      ).to.be.revertedWithCustomError(factory, "InvalidMaxSupply");
    });

    it("Created collection should be fully functional", async function () {
      const tx = await factory.connect(creator1).createCollection(
        "Functional", "FUNC", 100, 1000, creator1.address, "ipfs://hidden"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const cloneAddr = event.args[0];

      const Collection = await ethers.getContractFactory("OmniNFTCollection");
      const coll = Collection.attach(cloneAddr);

      // Configure and activate a phase
      await coll.connect(creator1).setPhase(1, 0, 5, ethers.ZeroHash);
      await coll.connect(creator1).setActivePhase(1);

      // Mint
      await coll.connect(user1).mint(3, []);
      expect(await coll.totalMinted()).to.equal(3);
      expect(await coll.ownerOf(0)).to.equal(user1.address);

      // Royalties
      const [receiver, amount] = await coll.royaltyInfo(0, ethers.parseEther("1"));
      expect(receiver).to.equal(creator1.address);
      expect(amount).to.equal(ethers.parseEther("0.1")); // 10%
    });
  });

  describe("Admin Functions", function () {
    it("Should update platform fee", async function () {
      await factory.setPlatformFee(500);
      expect(await factory.platformFeeBps()).to.equal(500);
    });

    it("Should reject fee above max", async function () {
      await expect(
        factory.setPlatformFee(1001)
      ).to.be.revertedWithCustomError(factory, "FeeTooHigh");
    });

    it("Should update implementation", async function () {
      const Collection = await ethers.getContractFactory("OmniNFTCollection");
      const newImpl = await Collection.deploy();
      await factory.setImplementation(await newImpl.getAddress());
      expect(await factory.implementation()).to.equal(await newImpl.getAddress());
    });

    it("Should reject zero implementation", async function () {
      await expect(
        factory.setImplementation(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(factory, "InvalidImplementation");
    });

    it("Should restrict admin functions to owner", async function () {
      await expect(
        factory.connect(creator1).setPlatformFee(100)
      ).to.be.revertedWithCustomError(factory, "OwnableUnauthorizedAccount");

      await expect(
        factory.connect(creator1).setImplementation(creator1.address)
      ).to.be.revertedWithCustomError(factory, "OwnableUnauthorizedAccount");
    });
  });
});

describe("OmniNFTRoyalty", function () {
  let royaltyRegistry;
  let owner, collOwner, user1;

  /**
   * @notice Ownable contract deployed by collOwner to use as collection address.
   * @dev After H-01 audit fix, first-time registration by non-admin callers
   *      requires ownership verification via IOwnable(collection).owner().
   *      EOA addresses cannot be used as collection parameters.
   */
  let collOwnerCollection;

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

  beforeEach(async function () {
    [owner, collOwner, user1] = await ethers.getSigners();

    const Royalty = await ethers.getContractFactory("OmniNFTRoyalty");
    royaltyRegistry = await Royalty.deploy();

    // Deploy Ownable contract so collOwner "owns" a collection address
    collOwnerCollection = await deployOwnableCollection(collOwner);
  });

  describe("Registration", function () {
    it("Should register royalty info", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 500
      );
      const info = await royaltyRegistry.royalties(collAddr);
      expect(info.recipient).to.equal(collOwner.address);
      expect(info.royaltyBps).to.equal(500);
      expect(info.registeredOwner).to.equal(collOwner.address);
    });

    it("Should track registered collections", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 500
      );
      expect(await royaltyRegistry.totalRegistered()).to.equal(1);
      expect(await royaltyRegistry.isRegistered(collAddr)).to.equal(true);
    });

    it("Should reject royalty above 25%", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await expect(
        royaltyRegistry.connect(collOwner).setRoyalty(
          collAddr, collOwner.address, 2501
        )
      ).to.be.revertedWithCustomError(royaltyRegistry, "RoyaltyTooHigh");
    });

    it("Should reject zero recipient", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await expect(
        royaltyRegistry.connect(collOwner).setRoyalty(
          collAddr, ethers.ZeroAddress, 500
        )
      ).to.be.revertedWithCustomError(royaltyRegistry, "InvalidRecipient");
    });

    it("Should only allow registered owner to update", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 500
      );
      await expect(
        royaltyRegistry.connect(user1).setRoyalty(
          collAddr, user1.address, 1000
        )
      ).to.be.revertedWithCustomError(royaltyRegistry, "NotCollectionOwner");
    });

    it("Should allow contract admin to override", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 500
      );
      // Admin (deployer) can update
      await royaltyRegistry.connect(owner).setRoyalty(
        collAddr, owner.address, 1000
      );
      const info = await royaltyRegistry.royalties(collAddr);
      expect(info.recipient).to.equal(owner.address);
      expect(info.royaltyBps).to.equal(1000);
    });
  });

  describe("Royalty Query", function () {
    it("Should calculate royalty from registry", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 1000 // 10%
      );
      const salePrice = ethers.parseEther("1");
      const [receiver, amount] = await royaltyRegistry.royaltyInfo(
        collAddr, 0, salePrice
      );
      expect(receiver).to.equal(collOwner.address);
      expect(amount).to.equal(ethers.parseEther("0.1"));
    });

    it("Should return zero for unregistered collection", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      const salePrice = ethers.parseEther("1");
      const [receiver, amount] = await royaltyRegistry.royaltyInfo(
        collAddr, 0, salePrice
      );
      expect(receiver).to.equal(ethers.ZeroAddress);
      expect(amount).to.equal(0);
    });
  });

  describe("Ownership Transfer", function () {
    it("Should transfer collection registry ownership", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 500
      );
      await royaltyRegistry.connect(collOwner).transferCollectionOwnership(
        collAddr, user1.address
      );
      const info = await royaltyRegistry.royalties(collAddr);
      expect(info.registeredOwner).to.equal(user1.address);
    });

    it("Should reject unauthorized transfer", async function () {
      const collAddr = await collOwnerCollection.getAddress();
      await royaltyRegistry.connect(collOwner).setRoyalty(
        collAddr, collOwner.address, 500
      );
      await expect(
        royaltyRegistry.connect(user1).transferCollectionOwnership(
          collAddr, user1.address
        )
      ).to.be.revertedWithCustomError(royaltyRegistry, "NotCollectionOwner");
    });
  });
});
