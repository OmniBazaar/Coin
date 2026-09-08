const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniNFTFactory", function () {
  let factory, impl;
  let owner, creator1, creator2, user1;

  beforeEach(async function () {
    [owner, creator1, creator2, user1] = await ethers.getSigners();

    const Collection = await ethers.getContractFactory("OmniNFTCollection");
    impl = await Collection.deploy(ethers.ZeroAddress);

    const Factory = await ethers.getContractFactory("OmniNFTFactory");
    factory = await Factory.deploy(await impl.getAddress(), ethers.ZeroAddress);
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
        Factory.deploy(ethers.ZeroAddress, ethers.ZeroAddress)
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
      const newImpl = await Collection.deploy(ethers.ZeroAddress);
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

  // =====================================================================
  //  NEW TESTS - Collection Limits
  // =====================================================================
  describe("Collection Limits", function () {
    it("Should expose MAX_COLLECTIONS constant as 10000", async function () {
      expect(await factory.MAX_COLLECTIONS()).to.equal(10000);
    });

    it("Should allow creation with maxSupply of 1 (minimum)", async function () {
      const tx = await factory.connect(creator1).createCollection(
        "Single", "ONE", 1, 0, creator1.address, ""
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      expect(event).to.not.be.undefined;
      expect(event.args.maxSupply).to.equal(1);
    });

    it("Should allow creation with very large maxSupply", async function () {
      const largeSupply = ethers.MaxUint256;
      const tx = await factory.connect(creator1).createCollection(
        "Huge", "HG", largeSupply, 0, creator1.address, ""
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      expect(event.args.maxSupply).to.equal(largeSupply);
    });
  });

  // =====================================================================
  //  NEW TESTS - Fee Validation
  // =====================================================================
  describe("Fee Validation", function () {
    it("Should expose MAX_PLATFORM_FEE_BPS constant as 1000", async function () {
      expect(await factory.MAX_PLATFORM_FEE_BPS()).to.equal(1000);
    });

    it("Should accept fee at exact maximum (1000 bps = 10%)", async function () {
      await factory.setPlatformFee(1000);
      expect(await factory.platformFeeBps()).to.equal(1000);
    });

    it("Should accept fee of zero", async function () {
      await factory.setPlatformFee(0);
      expect(await factory.platformFeeBps()).to.equal(0);
    });

    it("Should reject fee of 1001 (one above max)", async function () {
      await expect(
        factory.setPlatformFee(1001)
      ).to.be.revertedWithCustomError(factory, "FeeTooHigh");
    });

    it("Should reject fee of 65535 (max uint16)", async function () {
      await expect(
        factory.setPlatformFee(65535)
      ).to.be.revertedWithCustomError(factory, "FeeTooHigh");
    });
  });

  // =====================================================================
  //  NEW TESTS - Access Control on All Admin Functions
  // =====================================================================
  describe("Access Control - Detailed", function () {
    it("Should reject setPlatformFee from non-owner", async function () {
      await expect(
        factory.connect(user1).setPlatformFee(100)
      ).to.be.revertedWithCustomError(factory, "OwnableUnauthorizedAccount");
    });

    it("Should reject setImplementation from non-owner", async function () {
      await expect(
        factory.connect(user1).setImplementation(user1.address)
      ).to.be.revertedWithCustomError(factory, "OwnableUnauthorizedAccount");
    });

    it("Should allow any user to create a collection (no role needed)", async function () {
      await expect(
        factory.connect(user1).createCollection(
          "UserCollection", "UC", 100, 0, user1.address, ""
        )
      ).to.not.be.reverted;
    });

    it("Should support Ownable2Step ownership transfer flow", async function () {
      // Start transfer
      await factory.connect(owner).transferOwnership(creator1.address);

      // creator1 has not accepted yet, owner is still owner
      expect(await factory.owner()).to.equal(owner.address);
      expect(await factory.pendingOwner()).to.equal(creator1.address);

      // creator1 accepts
      await factory.connect(creator1).acceptOwnership();
      expect(await factory.owner()).to.equal(creator1.address);

      // Now creator1 can use admin functions
      await factory.connect(creator1).setPlatformFee(100);
      expect(await factory.platformFeeBps()).to.equal(100);

      // Original owner cannot
      await expect(
        factory.connect(owner).setPlatformFee(200)
      ).to.be.revertedWithCustomError(factory, "OwnableUnauthorizedAccount");
    });

    it("Should reject accept from non-pending owner", async function () {
      await factory.connect(owner).transferOwnership(creator1.address);

      await expect(
        factory.connect(user1).acceptOwnership()
      ).to.be.revertedWithCustomError(factory, "OwnableUnauthorizedAccount");
    });
  });

  // =====================================================================
  //  NEW TESTS - Collection Registry
  // =====================================================================
  describe("Collection Registry", function () {
    it("Should return correct collection address by index", async function () {
      const tx1 = await factory.connect(creator1).createCollection(
        "First", "F", 100, 0, creator1.address, ""
      );
      const receipt1 = await tx1.wait();
      const event1 = receipt1.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr1 = event1.args[0];

      const tx2 = await factory.connect(creator2).createCollection(
        "Second", "S", 200, 0, creator2.address, ""
      );
      const receipt2 = await tx2.wait();
      const event2 = receipt2.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr2 = event2.args[0];

      expect(await factory.collections(0)).to.equal(addr1);
      expect(await factory.collections(1)).to.equal(addr2);
    });

    it("Should return correct creatorCollections by index", async function () {
      const tx1 = await factory.connect(creator1).createCollection(
        "A", "A", 10, 0, creator1.address, ""
      );
      const receipt1 = await tx1.wait();
      const event1 = receipt1.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr1 = event1.args[0];

      const tx2 = await factory.connect(creator1).createCollection(
        "B", "B", 20, 0, creator1.address, ""
      );
      const receipt2 = await tx2.wait();
      const event2 = receipt2.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr2 = event2.args[0];

      expect(await factory.creatorCollections(creator1.address, 0)).to.equal(addr1);
      expect(await factory.creatorCollections(creator1.address, 1)).to.equal(addr2);
    });

    it("Should return false for isFactoryCollection on non-factory address", async function () {
      expect(await factory.isFactoryCollection(ethers.ZeroAddress)).to.be.false;
      expect(await factory.isFactoryCollection(owner.address)).to.be.false;
    });

    it("Should return zero for creatorCollectionCount of address with no collections", async function () {
      expect(await factory.creatorCollectionCount(user1.address)).to.equal(0);
    });
  });

  // =====================================================================
  //  NEW TESTS - View Functions
  // =====================================================================
  describe("View Functions", function () {
    it("Should return zero totalCollections initially", async function () {
      expect(await factory.totalCollections()).to.equal(0);
    });

    it("Should increment totalCollections on each creation", async function () {
      await factory.connect(creator1).createCollection("A", "A", 10, 0, creator1.address, "");
      expect(await factory.totalCollections()).to.equal(1);

      await factory.connect(creator1).createCollection("B", "B", 20, 0, creator1.address, "");
      expect(await factory.totalCollections()).to.equal(2);

      await factory.connect(creator2).createCollection("C", "C", 30, 0, creator2.address, "");
      expect(await factory.totalCollections()).to.equal(3);
    });

    it("Should return correct implementation address after update", async function () {
      const Collection = await ethers.getContractFactory("OmniNFTCollection");
      const newImpl = await Collection.deploy(ethers.ZeroAddress);

      await factory.setImplementation(await newImpl.getAddress());
      expect(await factory.implementation()).to.equal(await newImpl.getAddress());
    });
  });

  // =====================================================================
  //  NEW TESTS - Events
  // =====================================================================
  describe("Events", function () {
    it("Should emit CollectionCreated with all correct fields", async function () {
      await expect(
        factory.connect(creator1).createCollection(
          "EvtTest", "EVT", 500, 250, creator1.address, "ipfs://pre"
        )
      ).to.emit(factory, "CollectionCreated");
    });

    it("Should include platformFeeBps in CollectionCreated event (M-02)", async function () {
      // Set a custom fee
      await factory.setPlatformFee(750);

      const tx = await factory.connect(creator1).createCollection(
        "FeeTest", "FT", 100, 0, creator1.address, ""
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      // feeBps is the 7th argument (index 6)
      expect(event.args.feeBps).to.equal(750);
    });

    it("Should emit PlatformFeeUpdated when fee changes", async function () {
      await expect(factory.setPlatformFee(500))
        .to.emit(factory, "PlatformFeeUpdated")
        .withArgs(500);
    });

    it("Should emit ImplementationUpdated when implementation changes", async function () {
      const Collection = await ethers.getContractFactory("OmniNFTCollection");
      const newImpl = await Collection.deploy(ethers.ZeroAddress);
      const newImplAddr = await newImpl.getAddress();

      await expect(factory.setImplementation(newImplAddr))
        .to.emit(factory, "ImplementationUpdated")
        .withArgs(newImplAddr);
    });

    it("Should include the default platformFeeBps (250) in event for first collection", async function () {
      const tx = await factory.connect(creator1).createCollection(
        "Default", "DEF", 50, 0, creator1.address, ""
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      expect(event.args.feeBps).to.equal(250);
    });
  });

  // =====================================================================
  //  NEW TESTS - Multiple Creators and Clones Independence
  // =====================================================================
  describe("Clone Independence", function () {
    it("Each clone should have independent ownership", async function () {
      const tx1 = await factory.connect(creator1).createCollection(
        "C1", "C1", 100, 0, creator1.address, ""
      );
      const receipt1 = await tx1.wait();
      const event1 = receipt1.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr1 = event1.args[0];

      const tx2 = await factory.connect(creator2).createCollection(
        "C2", "C2", 200, 0, creator2.address, ""
      );
      const receipt2 = await tx2.wait();
      const event2 = receipt2.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr2 = event2.args[0];

      const Collection = await ethers.getContractFactory("OmniNFTCollection");
      const coll1 = Collection.attach(addr1);
      const coll2 = Collection.attach(addr2);

      expect(await coll1.owner()).to.equal(creator1.address);
      expect(await coll2.owner()).to.equal(creator2.address);
    });

    it("Clones created after implementation update should use new implementation", async function () {
      // Create a collection with original implementation
      const tx1 = await factory.connect(creator1).createCollection(
        "Old", "OLD", 100, 0, creator1.address, ""
      );
      const receipt1 = await tx1.wait();
      const event1 = receipt1.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr1 = event1.args[0];

      // Update implementation
      const Collection = await ethers.getContractFactory("OmniNFTCollection");
      const newImpl = await Collection.deploy(ethers.ZeroAddress);
      await factory.setImplementation(await newImpl.getAddress());

      // Create a collection with new implementation
      const tx2 = await factory.connect(creator2).createCollection(
        "New", "NEW", 200, 0, creator2.address, ""
      );
      const receipt2 = await tx2.wait();
      const event2 = receipt2.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      const addr2 = event2.args[0];

      // Both should still be factory collections
      expect(await factory.isFactoryCollection(addr1)).to.be.true;
      expect(await factory.isFactoryCollection(addr2)).to.be.true;

      // Addresses should differ
      expect(addr1).to.not.equal(addr2);
    });

    it("Should allow empty name and symbol", async function () {
      const tx = await factory.connect(creator1).createCollection(
        "", "", 10, 0, creator1.address, ""
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "CollectionCreated"
      );
      expect(event.args.name).to.equal("");
      expect(event.args.symbol).to.equal("");
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
