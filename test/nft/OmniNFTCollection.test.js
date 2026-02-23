const { expect } = require("chai");
const { ethers } = require("hardhat");
const { MerkleTree } = require("merkletreejs");

/** keccak256 wrapper compatible with merkletreejs (accepts Buffer, returns Buffer) */
function keccak256(data) {
  return Buffer.from(ethers.keccak256(data).slice(2), 'hex');
}

describe("OmniNFTCollection", function () {
  let collection;
  let owner, creator, user1, user2, user3;

  const MAX_SUPPLY = 100;
  const ROYALTY_BPS = 500; // 5%
  const UNREVEALED_URI = "ipfs://QmUnrevealed/hidden.json";
  const REVEALED_BASE_URI = "ipfs://QmRevealed/";

  beforeEach(async function () {
    [owner, creator, user1, user2, user3] = await ethers.getSigners();

    const Collection = await ethers.getContractFactory("OmniNFTCollection");
    collection = await Collection.deploy();

    // Clone pattern: we deploy a fresh instance and initialize it.
    // For testing, deploy a second instance and initialize it directly.
    const freshCollection = await Collection.deploy();
    // The constructor marks it as initialized, so we test via factory pattern.
    // For unit tests, deploy without constructor init by using a helper.
  });

  /**
   * Helper: deploy an uninitialized clone-like collection.
   * We use the factory test for true clones. Here we just test
   * the implementation contract's features after factory-init.
   */
  async function deployInitializedCollection(params = {}) {
    // Deploy the factory, which will create a proper clone
    const Collection = await ethers.getContractFactory("OmniNFTCollection");
    const impl = await Collection.deploy();

    const Factory = await ethers.getContractFactory("OmniNFTFactory");
    const factory = await Factory.deploy(await impl.getAddress());

    const tx = await factory.connect(params.creator || creator).createCollection(
      params.name || "TestNFT",
      params.symbol || "TNFT",
      params.maxSupply || MAX_SUPPLY,
      params.royaltyBps || ROYALTY_BPS,
      params.royaltyRecipient || (params.creator || creator).address,
      params.unrevealedURI || UNREVEALED_URI
    );

    const receipt = await tx.wait();
    const event = receipt.logs.find(
      (l) => l.fragment && l.fragment.name === "CollectionCreated"
    );
    const cloneAddress = event.args[0];

    return Collection.attach(cloneAddress);
  }

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      const coll = await deployInitializedCollection();
      expect(await coll.owner()).to.equal(creator.address);
      expect(await coll.maxSupply()).to.equal(MAX_SUPPLY);
      expect(await coll.initialized()).to.equal(true);
      expect(await coll.unrevealedURI()).to.equal(UNREVEALED_URI);
    });

    it("Should not allow double initialization", async function () {
      const coll = await deployInitializedCollection();
      await expect(
        coll.initialize(
          user1.address, "X", "X", 10, 100, user1.address, "ipfs://x"
        )
      ).to.be.revertedWithCustomError(coll, "AlreadyInitialized");
    });

    it("Should reject royalty above 25%", async function () {
      await expect(
        deployInitializedCollection({ royaltyBps: 2501 })
      ).to.be.revertedWithCustomError(collection, "RoyaltyTooHigh");
    });
  });

  describe("Phase Configuration", function () {
    let coll;

    beforeEach(async function () {
      coll = await deployInitializedCollection();
    });

    it("Should configure a phase", async function () {
      const price = ethers.parseEther("0.05");
      await coll.connect(creator).setPhase(1, price, 5, ethers.ZeroHash);
      const phase = await coll.phases(1);
      expect(phase.price).to.equal(price);
      expect(phase.maxPerWallet).to.equal(5);
      expect(phase.active).to.equal(false);
    });

    it("Should reject phase 0", async function () {
      await expect(
        coll.connect(creator).setPhase(0, 0, 5, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(coll, "ZeroQuantity");
    });

    it("Should activate and deactivate phases", async function () {
      await coll.connect(creator).setPhase(1, 0, 5, ethers.ZeroHash);
      await coll.connect(creator).setPhase(2, ethers.parseEther("0.1"), 3, ethers.ZeroHash);

      await coll.connect(creator).setActivePhase(1);
      expect(await coll.activePhase()).to.equal(1);
      expect((await coll.phases(1)).active).to.equal(true);

      await coll.connect(creator).setActivePhase(2);
      expect(await coll.activePhase()).to.equal(2);
      expect((await coll.phases(1)).active).to.equal(false);
      expect((await coll.phases(2)).active).to.equal(true);
    });

    it("Should not allow non-owner to configure phases", async function () {
      await expect(
        coll.connect(user1).setPhase(1, 0, 5, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(coll, "NotOwner");
    });
  });

  describe("Public Minting", function () {
    let coll;

    beforeEach(async function () {
      coll = await deployInitializedCollection();
      // Set up a free public phase with limit 10
      await coll.connect(creator).setPhase(1, 0, 10, ethers.ZeroHash);
      await coll.connect(creator).setActivePhase(1);
    });

    it("Should mint single token", async function () {
      await coll.connect(user1).mint(1, []);
      expect(await coll.totalMinted()).to.equal(1);
      expect(await coll.ownerOf(0)).to.equal(user1.address);
    });

    it("Should mint multiple tokens", async function () {
      await coll.connect(user1).mint(5, []);
      expect(await coll.totalMinted()).to.equal(5);
      for (let i = 0; i < 5; i++) {
        expect(await coll.ownerOf(i)).to.equal(user1.address);
      }
    });

    it("Should enforce per-wallet limit", async function () {
      await coll.connect(user1).mint(10, []);
      await expect(
        coll.connect(user1).mint(1, [])
      ).to.be.revertedWithCustomError(coll, "WalletLimitExceeded");
    });

    it("Should enforce max supply", async function () {
      // Mint to limit via owner batch mint
      await coll.connect(creator).batchMint(creator.address, MAX_SUPPLY);
      await expect(
        coll.connect(user1).mint(1, [])
      ).to.be.revertedWithCustomError(coll, "MaxSupplyExceeded");
    });

    it("Should reject minting when no phase is active", async function () {
      await coll.connect(creator).setActivePhase(0);
      await expect(
        coll.connect(user1).mint(1, [])
      ).to.be.revertedWithCustomError(coll, "PhaseNotActive");
    });

    it("Should reject zero quantity", async function () {
      await expect(
        coll.connect(user1).mint(0, [])
      ).to.be.revertedWithCustomError(coll, "ZeroQuantity");
    });
  });

  describe("Paid Minting", function () {
    let coll;
    const MINT_PRICE = ethers.parseEther("0.05");

    beforeEach(async function () {
      coll = await deployInitializedCollection();
      await coll.connect(creator).setPhase(1, MINT_PRICE, 5, ethers.ZeroHash);
      await coll.connect(creator).setActivePhase(1);
    });

    it("Should mint with correct payment", async function () {
      await coll.connect(user1).mint(2, [], { value: MINT_PRICE * 2n });
      expect(await coll.totalMinted()).to.equal(2);
    });

    it("Should reject incorrect payment", async function () {
      await expect(
        coll.connect(user1).mint(1, [], { value: MINT_PRICE - 1n })
      ).to.be.revertedWithCustomError(coll, "IncorrectPayment");
    });

    it("Should accumulate contract balance", async function () {
      await coll.connect(user1).mint(3, [], { value: MINT_PRICE * 3n });
      const balance = await ethers.provider.getBalance(await coll.getAddress());
      expect(balance).to.equal(MINT_PRICE * 3n);
    });
  });

  describe("Whitelist Minting", function () {
    let coll;
    let merkleTree;
    let merkleRoot;

    /**
     * M-03 audit fix: Merkle leaf now includes block.chainid, contract
     * address, and activePhase to prevent cross-chain / cross-collection /
     * cross-phase proof reuse.
     */
    function buildLeaf(collectionAddr, phaseId, userAddr) {
      return ethers.keccak256(
        ethers.solidityPacked(
          ["uint256", "address", "uint8", "address"],
          [1337, collectionAddr, phaseId, userAddr]  // hardhat chainId = 1337
        )
      );
    }

    beforeEach(async function () {
      coll = await deployInitializedCollection();
      const collAddr = await coll.getAddress();
      const phaseId = 1;

      // Build Merkle tree with user1 and user2 using the M-03 leaf format
      const leaves = [user1.address, user2.address].map((addr) =>
        buildLeaf(collAddr, phaseId, addr)
      );
      merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });
      merkleRoot = merkleTree.getHexRoot();

      await coll.connect(creator).setPhase(phaseId, 0, 3, merkleRoot);
      await coll.connect(creator).setActivePhase(phaseId);
    });

    it("Should allow whitelisted user to mint", async function () {
      const collAddr = await coll.getAddress();
      const leaf = buildLeaf(collAddr, 1, user1.address);
      const proof = merkleTree.getHexProof(leaf);

      await coll.connect(user1).mint(1, proof);
      expect(await coll.ownerOf(0)).to.equal(user1.address);
    });

    it("Should reject non-whitelisted user", async function () {
      const collAddr = await coll.getAddress();
      const leaf = buildLeaf(collAddr, 1, user3.address);
      const proof = merkleTree.getHexProof(leaf);

      await expect(
        coll.connect(user3).mint(1, proof)
      ).to.be.revertedWithCustomError(coll, "InvalidProof");
    });
  });

  describe("Batch Mint", function () {
    let coll;

    beforeEach(async function () {
      coll = await deployInitializedCollection();
    });

    it("Should batch mint to recipient", async function () {
      await coll.connect(creator).batchMint(user1.address, 10);
      expect(await coll.totalMinted()).to.equal(10);
      expect(await coll.ownerOf(0)).to.equal(user1.address);
      expect(await coll.ownerOf(9)).to.equal(user1.address);
    });

    it("Should reject batch mint from non-owner", async function () {
      await expect(
        coll.connect(user1).batchMint(user1.address, 5)
      ).to.be.revertedWithCustomError(coll, "NotOwner");
    });

    it("Should enforce max supply on batch mint", async function () {
      // H-01 added MAX_BATCH_SIZE = 100, which equals MAX_SUPPLY here.
      // First batch mint 50, then try to mint 51 more (within batch limit
      // but exceeding total supply).
      await coll.connect(creator).batchMint(creator.address, 50);
      await expect(
        coll.connect(creator).batchMint(creator.address, 51)
      ).to.be.revertedWithCustomError(coll, "MaxSupplyExceeded");
    });
  });

  describe("Reveal", function () {
    let coll;

    beforeEach(async function () {
      coll = await deployInitializedCollection();
      await coll.connect(creator).setPhase(1, 0, 10, ethers.ZeroHash);
      await coll.connect(creator).setActivePhase(1);
      await coll.connect(user1).mint(1, []);
    });

    it("Should show unrevealed URI before reveal", async function () {
      expect(await coll.tokenURI(0)).to.equal(UNREVEALED_URI);
    });

    it("Should reveal with correct base URI", async function () {
      await coll.connect(creator).reveal(REVEALED_BASE_URI);
      expect(await coll.revealed()).to.equal(true);
      expect(await coll.tokenURI(0)).to.equal(REVEALED_BASE_URI + "0.json");
    });

    it("Should not allow double reveal", async function () {
      await coll.connect(creator).reveal(REVEALED_BASE_URI);
      await expect(
        coll.connect(creator).reveal("ipfs://other/")
      ).to.be.revertedWithCustomError(coll, "AlreadyRevealed");
    });

    it("Should not allow non-owner to reveal", async function () {
      await expect(
        coll.connect(user1).reveal(REVEALED_BASE_URI)
      ).to.be.revertedWithCustomError(coll, "NotOwner");
    });
  });

  describe("ERC-2981 Royalties", function () {
    let coll;

    beforeEach(async function () {
      coll = await deployInitializedCollection({ royaltyBps: 1000 }); // 10%
    });

    it("Should return correct royalty info", async function () {
      const salePrice = ethers.parseEther("1");
      const [receiver, amount] = await coll.royaltyInfo(0, salePrice);
      expect(receiver).to.equal(creator.address);
      expect(amount).to.equal(ethers.parseEther("0.1")); // 10%
    });

    it("Should support ERC-2981 interface", async function () {
      // ERC-2981 interfaceId = 0x2a55205a
      expect(await coll.supportsInterface("0x2a55205a")).to.equal(true);
    });

    it("Should support ERC-721 interface", async function () {
      // ERC-721 interfaceId = 0x80ac58cd
      expect(await coll.supportsInterface("0x80ac58cd")).to.equal(true);
    });
  });

  describe("Withdrawal", function () {
    let coll;
    const MINT_PRICE = ethers.parseEther("0.1");

    beforeEach(async function () {
      coll = await deployInitializedCollection();
      await coll.connect(creator).setPhase(1, MINT_PRICE, 10, ethers.ZeroHash);
      await coll.connect(creator).setActivePhase(1);
      // Mint 5 tokens to generate revenue
      await coll.connect(user1).mint(5, [], { value: MINT_PRICE * 5n });
    });

    it("Should withdraw full balance to owner", async function () {
      const balanceBefore = await ethers.provider.getBalance(creator.address);
      const tx = await coll.connect(creator).withdraw();
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const balanceAfter = await ethers.provider.getBalance(creator.address);
      expect(balanceAfter - balanceBefore + gasCost).to.equal(MINT_PRICE * 5n);
    });

    it("Should reject withdrawal from non-owner", async function () {
      await expect(
        coll.connect(user1).withdraw()
      ).to.be.revertedWithCustomError(coll, "NotOwner");
    });
  });

  describe("Ownership Transfer", function () {
    let coll;

    beforeEach(async function () {
      coll = await deployInitializedCollection();
    });

    it("Should transfer ownership", async function () {
      await coll.connect(creator).transferOwnership(user1.address);
      expect(await coll.owner()).to.equal(user1.address);
    });

    it("Should reject transfer to zero address", async function () {
      await expect(
        coll.connect(creator).transferOwnership(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(coll, "TransferFailed");
    });
  });
});
