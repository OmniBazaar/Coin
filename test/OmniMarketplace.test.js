const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniMarketplace", function () {
  let marketplace;
  let owner, creator, creator2, other;

  // Convenience constants
  const ONE_DAY = 86400;
  const SIXTY_DAYS = 60 * ONE_DAY;
  const THREE_SIXTY_FIVE_DAYS = 365 * ONE_DAY;
  const PRICE = ethers.parseEther("100");

  // Helper: generate unique bytes32 values
  function randomBytes32() {
    return ethers.hexlify(ethers.randomBytes(32));
  }

  // Helper: build EIP-712 domain for the current marketplace instance
  async function getDomain() {
    return {
      name: "OmniMarketplace",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: await marketplace.getAddress(),
    };
  }

  // EIP-712 types for Listing
  const LISTING_TYPES = {
    Listing: [
      { name: "ipfsCID", type: "bytes32" },
      { name: "contentHash", type: "bytes32" },
      { name: "price", type: "uint256" },
      { name: "expiry", type: "uint256" },
      { name: "nonce", type: "uint256" },
    ],
  };

  // Helper: sign a listing with EIP-712
  async function signListing(signer, ipfsCID, contentHash, price, expiry) {
    const domain = await getDomain();
    const nonce = await marketplace.getNonce(signer.address);
    const value = { ipfsCID, contentHash, price, expiry, nonce };
    const signature = await signer.signTypedData(domain, LISTING_TYPES, value);
    return signature;
  }

  beforeEach(async function () {
    [owner, creator, creator2, other] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("OmniMarketplace");
    marketplace = await upgrades.deployProxy(Factory, [], {
      initializer: "initialize",
      kind: "uups",
    });
    await marketplace.waitForDeployment();
  });

  // ================================================================
  // 1. Initialization
  // ================================================================
  describe("Initialization", function () {
    it("Should set nextListingId to 1", async function () {
      expect(await marketplace.nextListingId()).to.equal(1);
    });

    it("Should set defaultExpiry to 60 days", async function () {
      expect(await marketplace.defaultExpiry()).to.equal(SIXTY_DAYS);
    });

    it("Should grant DEFAULT_ADMIN_ROLE to deployer", async function () {
      const DEFAULT_ADMIN_ROLE = await marketplace.DEFAULT_ADMIN_ROLE();
      expect(await marketplace.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be
        .true;
    });

    it("Should grant MARKETPLACE_ADMIN_ROLE to deployer", async function () {
      const MARKETPLACE_ADMIN_ROLE =
        await marketplace.MARKETPLACE_ADMIN_ROLE();
      expect(
        await marketplace.hasRole(MARKETPLACE_ADMIN_ROLE, owner.address)
      ).to.be.true;
    });

    it("Should expose a non-zero domainSeparator", async function () {
      const ds = await marketplace.domainSeparator();
      expect(ds).to.not.equal(ethers.ZeroHash);
    });
  });

  // ================================================================
  // 2. registerListingDirect
  // ================================================================
  describe("registerListingDirect", function () {
    it("Should create a listing with correct storage values", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const futureExpiry =
        (await time.latest()) + SIXTY_DAYS;

      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, futureExpiry);

      const listing = await marketplace.listings(1);
      expect(listing.creator).to.equal(creator.address);
      expect(listing.ipfsCID).to.equal(ipfsCID);
      expect(listing.contentHash).to.equal(contentHash);
      expect(listing.price).to.equal(PRICE);
      expect(listing.expiry).to.equal(futureExpiry);
      expect(listing.active).to.be.true;
    });

    it("Should emit ListingRegistered event", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const futureExpiry =
        (await time.latest()) + SIXTY_DAYS;

      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(ipfsCID, contentHash, PRICE, futureExpiry)
      )
        .to.emit(marketplace, "ListingRegistered")
        .withArgs(1, creator.address, ipfsCID, contentHash, PRICE, futureExpiry);
    });

    it("Should increment nextListingId", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();

      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);

      expect(await marketplace.nextListingId()).to.equal(2);
    });

    it("Should increment listingCount and totalListingsCreated", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();

      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);

      expect(await marketplace.listingCount(creator.address)).to.equal(1);
      expect(
        await marketplace.totalListingsCreated(creator.address)
      ).to.equal(1);
    });

    it("Should apply defaultExpiry when expiry is 0", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();

      const tx = await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      const block = await tx.getBlock();

      const listing = await marketplace.listings(1);
      expect(listing.expiry).to.equal(block.timestamp + SIXTY_DAYS);
    });

    it("Should cap expiry at MAX_EXPIRY_DURATION", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const now = await time.latest();
      // One second beyond 365 days from now
      const tooFar = now + THREE_SIXTY_FIVE_DAYS + 2;

      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(ipfsCID, contentHash, PRICE, tooFar)
      ).to.be.revertedWithCustomError(marketplace, "ExpiryTooFar");
    });

    it("Should accept expiry exactly at MAX_EXPIRY_DURATION boundary", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const now = await time.latest();
      // Exactly 365 days from now (block.timestamp at execution may tick +1)
      const exactMax = now + THREE_SIXTY_FIVE_DAYS;

      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(ipfsCID, contentHash, PRICE, exactMax)
      ).to.not.be.reverted;
    });

    it("Should revert on duplicate CID", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();

      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);

      await expect(
        marketplace
          .connect(creator2)
          .registerListingDirect(ipfsCID, randomBytes32(), PRICE, 0)
      ).to.be.revertedWithCustomError(marketplace, "DuplicateListing");
    });

    it("Should revert on zero price", async function () {
      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(randomBytes32(), randomBytes32(), 0, 0)
      ).to.be.revertedWithCustomError(marketplace, "ZeroPrice");
    });

    it("Should revert on zero CID", async function () {
      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(
            ethers.ZeroHash,
            randomBytes32(),
            PRICE,
            0
          )
      ).to.be.revertedWithCustomError(marketplace, "InvalidIPFSCID");
    });

    it("Should revert on zero contentHash", async function () {
      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(
            randomBytes32(),
            ethers.ZeroHash,
            PRICE,
            0
          )
      ).to.be.revertedWithCustomError(marketplace, "InvalidContentHash");
    });
  });

  // ================================================================
  // 3. registerListing (EIP-712 signature)
  // ================================================================
  describe("registerListing (EIP-712)", function () {
    it("Should accept a valid EIP-712 signature", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const expiry = (await time.latest()) + SIXTY_DAYS;

      const sig = await signListing(creator, ipfsCID, contentHash, PRICE, expiry);

      await expect(
        marketplace
          .connect(owner) // relayer submits on behalf of creator
          .registerListing(creator.address, ipfsCID, contentHash, PRICE, expiry, sig)
      )
        .to.emit(marketplace, "ListingRegistered")
        .withArgs(1, creator.address, ipfsCID, contentHash, PRICE, expiry);

      const listing = await marketplace.listings(1);
      expect(listing.creator).to.equal(creator.address);
      expect(listing.active).to.be.true;
    });

    it("Should reject a signature from a different signer", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const expiry = (await time.latest()) + SIXTY_DAYS;

      // creator2 signs but we claim creator is the creator
      const domain = await getDomain();
      const nonce = await marketplace.getNonce(creator.address);
      const sig = await creator2.signTypedData(domain, LISTING_TYPES, {
        ipfsCID,
        contentHash,
        price: PRICE,
        expiry,
        nonce,
      });

      await expect(
        marketplace
          .connect(owner)
          .registerListing(creator.address, ipfsCID, contentHash, PRICE, expiry, sig)
      ).to.be.revertedWithCustomError(marketplace, "InvalidSignature");
    });

    it("Should increment the nonce after successful registration", async function () {
      expect(await marketplace.getNonce(creator.address)).to.equal(0);

      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const expiry = (await time.latest()) + SIXTY_DAYS;

      const sig = await signListing(creator, ipfsCID, contentHash, PRICE, expiry);
      await marketplace
        .connect(owner)
        .registerListing(creator.address, ipfsCID, contentHash, PRICE, expiry, sig);

      expect(await marketplace.getNonce(creator.address)).to.equal(1);
    });

    it("Should reject replay of same signature (nonce used)", async function () {
      const ipfsCID1 = randomBytes32();
      const ipfsCID2 = randomBytes32();
      const contentHash = randomBytes32();
      const expiry = (await time.latest()) + SIXTY_DAYS;

      const sig = await signListing(
        creator,
        ipfsCID1,
        contentHash,
        PRICE,
        expiry
      );

      await marketplace
        .connect(owner)
        .registerListing(creator.address, ipfsCID1, contentHash, PRICE, expiry, sig);

      // Attempt to replay the same signature with a different CID
      await expect(
        marketplace
          .connect(owner)
          .registerListing(creator.address, ipfsCID2, contentHash, PRICE, expiry, sig)
      ).to.be.revertedWithCustomError(marketplace, "InvalidSignature");
    });

    it("Should apply defaultExpiry when expiry is 0 (signed)", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();

      // M-02 fix: The contract now preserves the original expiry (0) for
      // signature verification, then substitutes the default expiry AFTER
      // the signature check passes. So signing with expiry=0 now works.
      const sig = await signListing(creator, ipfsCID, contentHash, PRICE, 0);

      const tx = await marketplace
        .connect(owner)
        .registerListing(creator.address, ipfsCID, contentHash, PRICE, 0, sig);
      const block = await tx.getBlock();

      const listing = await marketplace.listings(1);
      // Verify that default expiry was applied
      expect(listing.expiry).to.equal(block.timestamp + SIXTY_DAYS);
      expect(listing.creator).to.equal(creator.address);
      expect(listing.active).to.be.true;
    });
  });

  // ================================================================
  // 4. delistListing
  // ================================================================
  describe("delistListing", function () {
    let listingId;
    let ipfsCID;

    beforeEach(async function () {
      ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      listingId = 1;
    });

    it("Should allow creator to delist", async function () {
      await expect(marketplace.connect(creator).delistListing(listingId))
        .to.emit(marketplace, "ListingDelisted")
        .withArgs(listingId, creator.address);

      const listing = await marketplace.listings(listingId);
      expect(listing.active).to.be.false;
    });

    it("Should decrement listingCount on delist", async function () {
      expect(await marketplace.listingCount(creator.address)).to.equal(1);

      await marketplace.connect(creator).delistListing(listingId);

      expect(await marketplace.listingCount(creator.address)).to.equal(0);
    });

    it("Should NOT decrement totalListingsCreated on delist", async function () {
      await marketplace.connect(creator).delistListing(listingId);
      expect(
        await marketplace.totalListingsCreated(creator.address)
      ).to.equal(1);
    });

    it("Should revert when non-creator tries to delist", async function () {
      await expect(
        marketplace.connect(other).delistListing(listingId)
      ).to.be.revertedWithCustomError(marketplace, "NotListingCreator");
    });

    it("Should revert when delisting an already-delisted listing", async function () {
      await marketplace.connect(creator).delistListing(listingId);

      await expect(
        marketplace.connect(creator).delistListing(listingId)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });

    it("Should revert when listing does not exist", async function () {
      await expect(
        marketplace.connect(creator).delistListing(999)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });
  });

  // ================================================================
  // 5. renewListing
  // ================================================================
  describe("renewListing", function () {
    let listingId;

    beforeEach(async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      listingId = 1;
    });

    it("Should extend expiry from current expiry when not yet expired", async function () {
      const listingBefore = await marketplace.listings(listingId);
      const oldExpiry = listingBefore.expiry;
      const additionalDuration = 30 * ONE_DAY;

      await marketplace
        .connect(creator)
        .renewListing(listingId, additionalDuration);

      const listingAfter = await marketplace.listings(listingId);
      // Since the listing has not expired, new expiry = oldExpiry + additionalDuration
      expect(listingAfter.expiry).to.equal(oldExpiry + BigInt(additionalDuration));
    });

    it("Should extend from block.timestamp when listing is expired", async function () {
      // Fast-forward past the 60-day expiry
      await time.increase(SIXTY_DAYS + 100);

      const additionalDuration = 30 * ONE_DAY;
      const tx = await marketplace
        .connect(creator)
        .renewListing(listingId, additionalDuration);
      const block = await tx.getBlock();

      const listing = await marketplace.listings(listingId);
      // expired, so base = block.timestamp
      expect(listing.expiry).to.equal(block.timestamp + additionalDuration);
    });

    it("Should emit ListingRenewed event", async function () {
      const additionalDuration = 7 * ONE_DAY;

      await expect(
        marketplace.connect(creator).renewListing(listingId, additionalDuration)
      ).to.emit(marketplace, "ListingRenewed");
    });

    it("Should revert when non-creator tries to renew", async function () {
      await expect(
        marketplace.connect(other).renewListing(listingId, ONE_DAY)
      ).to.be.revertedWithCustomError(marketplace, "NotListingCreator");
    });

    it("Should revert when listing does not exist", async function () {
      await expect(
        marketplace.connect(creator).renewListing(999, ONE_DAY)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });

    it("Should revert when renewal exceeds MAX_EXPIRY_DURATION from now", async function () {
      // Try to renew way past 365 days from now
      await expect(
        marketplace
          .connect(creator)
          .renewListing(listingId, THREE_SIXTY_FIVE_DAYS + ONE_DAY)
      ).to.be.revertedWithCustomError(marketplace, "ExpiryTooFar");
    });

    it("Should revert when renewing a delisted listing", async function () {
      await marketplace.connect(creator).delistListing(listingId);
      await expect(
        marketplace.connect(creator).renewListing(listingId, ONE_DAY)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });
  });

  // ================================================================
  // 6. updatePrice
  // ================================================================
  describe("updatePrice", function () {
    let listingId;

    beforeEach(async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      listingId = 1;
    });

    it("Should update the price and emit event", async function () {
      const newPrice = ethers.parseEther("200");

      await expect(
        marketplace.connect(creator).updatePrice(listingId, newPrice)
      )
        .to.emit(marketplace, "ListingPriceUpdated")
        .withArgs(listingId, PRICE, newPrice);

      const listing = await marketplace.listings(listingId);
      expect(listing.price).to.equal(newPrice);
    });

    it("Should revert on zero price", async function () {
      await expect(
        marketplace.connect(creator).updatePrice(listingId, 0)
      ).to.be.revertedWithCustomError(marketplace, "ZeroPrice");
    });

    it("Should revert when non-creator tries to update price", async function () {
      await expect(
        marketplace
          .connect(other)
          .updatePrice(listingId, ethers.parseEther("50"))
      ).to.be.revertedWithCustomError(marketplace, "NotListingCreator");
    });

    it("Should revert when listing does not exist", async function () {
      await expect(
        marketplace
          .connect(creator)
          .updatePrice(999, ethers.parseEther("50"))
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });

    it("Should revert when listing is delisted", async function () {
      await marketplace.connect(creator).delistListing(listingId);

      await expect(
        marketplace
          .connect(creator)
          .updatePrice(listingId, ethers.parseEther("50"))
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });
  });

  // ================================================================
  // 7. verifyContent
  // ================================================================
  describe("verifyContent", function () {
    let listingId;
    let storedContentHash;

    beforeEach(async function () {
      const ipfsCID = randomBytes32();
      storedContentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, storedContentHash, PRICE, 0);
      listingId = 1;
    });

    it("Should return true for matching content hash", async function () {
      expect(
        await marketplace.verifyContent(listingId, storedContentHash)
      ).to.be.true;
    });

    it("Should return false for mismatched content hash", async function () {
      expect(
        await marketplace.verifyContent(listingId, randomBytes32())
      ).to.be.false;
    });

    it("Should revert for non-existent listing", async function () {
      await expect(
        marketplace.verifyContent(999, storedContentHash)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotFound");
    });
  });

  // ================================================================
  // 8. isListingValid
  // ================================================================
  describe("isListingValid", function () {
    let listingId;

    beforeEach(async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      listingId = 1;
    });

    it("Should return true for active, non-expired listing", async function () {
      expect(await marketplace.isListingValid(listingId)).to.be.true;
    });

    it("Should return false after expiry", async function () {
      await time.increase(SIXTY_DAYS + 1);
      expect(await marketplace.isListingValid(listingId)).to.be.false;
    });

    it("Should return false for a delisted listing", async function () {
      await marketplace.connect(creator).delistListing(listingId);
      expect(await marketplace.isListingValid(listingId)).to.be.false;
    });

    it("Should return false for non-existent listing", async function () {
      expect(await marketplace.isListingValid(999)).to.be.false;
    });
  });

  // ================================================================
  // 9. getListingByCID
  // ================================================================
  describe("getListingByCID", function () {
    it("Should return correct listing ID for a known CID", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);

      expect(await marketplace.getListingByCID(ipfsCID)).to.equal(1);
    });

    it("Should return 0 for unknown CID", async function () {
      expect(await marketplace.getListingByCID(randomBytes32())).to.equal(0);
    });
  });

  // ================================================================
  // 10. Admin functions
  // ================================================================
  describe("Admin functions", function () {
    it("Should allow MARKETPLACE_ADMIN to setDefaultExpiry", async function () {
      const newDefault = 90 * ONE_DAY;
      await marketplace.connect(owner).setDefaultExpiry(newDefault);
      expect(await marketplace.defaultExpiry()).to.equal(newDefault);
    });

    it("Should reject setDefaultExpiry from non-admin", async function () {
      await expect(
        marketplace.connect(other).setDefaultExpiry(30 * ONE_DAY)
      ).to.be.reverted;
    });

    it("Should apply updated defaultExpiry to new listings", async function () {
      const newDefault = 90 * ONE_DAY;
      await marketplace.connect(owner).setDefaultExpiry(newDefault);

      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const tx = await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      const block = await tx.getBlock();

      const listing = await marketplace.listings(1);
      expect(listing.expiry).to.equal(block.timestamp + newDefault);
    });

    it("Should allow DEFAULT_ADMIN to pause", async function () {
      await marketplace.connect(owner).pause();
      expect(await marketplace.paused()).to.be.true;
    });

    it("Should block listing creation while paused", async function () {
      await marketplace.connect(owner).pause();

      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(
            randomBytes32(),
            randomBytes32(),
            PRICE,
            0
          )
      ).to.be.revertedWithCustomError(marketplace, "EnforcedPause");
    });

    it("Should block EIP-712 listing creation while paused", async function () {
      await marketplace.connect(owner).pause();

      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const expiry = (await time.latest()) + SIXTY_DAYS;
      const sig = await signListing(
        creator,
        ipfsCID,
        contentHash,
        PRICE,
        expiry
      );

      await expect(
        marketplace
          .connect(owner)
          .registerListing(creator.address, ipfsCID, contentHash, PRICE, expiry, sig)
      ).to.be.revertedWithCustomError(marketplace, "EnforcedPause");
    });

    it("Should allow unpause and re-enable listing creation", async function () {
      await marketplace.connect(owner).pause();
      await marketplace.connect(owner).unpause();

      await expect(
        marketplace
          .connect(creator)
          .registerListingDirect(
            randomBytes32(),
            randomBytes32(),
            PRICE,
            0
          )
      ).to.not.be.reverted;
    });

    it("Should reject pause from non-admin", async function () {
      await expect(marketplace.connect(other).pause()).to.be.reverted;
    });

    it("Should reject unpause from non-admin", async function () {
      await marketplace.connect(owner).pause();
      await expect(marketplace.connect(other).unpause()).to.be.reverted;
    });
  });

  // ================================================================
  // 11. Edge cases & integration
  // ================================================================
  describe("Edge cases and integration", function () {
    it("Should support multiple creators with independent listings", async function () {
      const cid1 = randomBytes32();
      const cid2 = randomBytes32();
      const hash1 = randomBytes32();
      const hash2 = randomBytes32();

      await marketplace
        .connect(creator)
        .registerListingDirect(cid1, hash1, PRICE, 0);
      await marketplace
        .connect(creator2)
        .registerListingDirect(cid2, hash2, ethers.parseEther("50"), 0);

      expect(await marketplace.listingCount(creator.address)).to.equal(1);
      expect(await marketplace.listingCount(creator2.address)).to.equal(1);

      const listing1 = await marketplace.listings(1);
      const listing2 = await marketplace.listings(2);
      expect(listing1.creator).to.equal(creator.address);
      expect(listing2.creator).to.equal(creator2.address);
    });

    it("Should track listingCount correctly across create and delist", async function () {
      const cid1 = randomBytes32();
      const cid2 = randomBytes32();

      await marketplace
        .connect(creator)
        .registerListingDirect(cid1, randomBytes32(), PRICE, 0);
      await marketplace
        .connect(creator)
        .registerListingDirect(cid2, randomBytes32(), PRICE, 0);

      expect(await marketplace.listingCount(creator.address)).to.equal(2);

      await marketplace.connect(creator).delistListing(1);
      expect(await marketplace.listingCount(creator.address)).to.equal(1);

      await marketplace.connect(creator).delistListing(2);
      expect(await marketplace.listingCount(creator.address)).to.equal(0);

      // totalListingsCreated stays at 2
      expect(
        await marketplace.totalListingsCreated(creator.address)
      ).to.equal(2);
    });

    it("Should allow delist even after expiry", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);

      // Fast-forward past expiry
      await time.increase(SIXTY_DAYS + 100);

      // Should still be delisted (active is still true even though expired)
      await expect(marketplace.connect(creator).delistListing(1)).to.not.be
        .reverted;

      const listing = await marketplace.listings(1);
      expect(listing.active).to.be.false;
    });

    it("Should handle getNonce correctly for unused address", async function () {
      expect(await marketplace.getNonce(other.address)).to.equal(0);
    });

    it("Should store createdAt timestamp correctly", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();

      const tx = await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);
      const block = await tx.getBlock();

      const listing = await marketplace.listings(1);
      expect(listing.createdAt).to.equal(block.timestamp);
    });

    it("Should handle successive EIP-712 listings with correct nonces", async function () {
      // First listing
      const cid1 = randomBytes32();
      const hash1 = randomBytes32();
      const expiry1 = (await time.latest()) + SIXTY_DAYS;
      const sig1 = await signListing(creator, cid1, hash1, PRICE, expiry1);
      await marketplace
        .connect(owner)
        .registerListing(creator.address, cid1, hash1, PRICE, expiry1, sig1);

      expect(await marketplace.getNonce(creator.address)).to.equal(1);

      // Second listing (nonce is now 1)
      const cid2 = randomBytes32();
      const hash2 = randomBytes32();
      const expiry2 = (await time.latest()) + SIXTY_DAYS;
      const sig2 = await signListing(creator, cid2, hash2, PRICE, expiry2);
      await marketplace
        .connect(owner)
        .registerListing(creator.address, cid2, hash2, PRICE, expiry2, sig2);

      expect(await marketplace.getNonce(creator.address)).to.equal(2);
      expect(await marketplace.nextListingId()).to.equal(3);
    });

    it("Should not allow pause to affect delist operations", async function () {
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(creator)
        .registerListingDirect(ipfsCID, contentHash, PRICE, 0);

      await marketplace.connect(owner).pause();

      // delistListing does NOT have whenNotPaused, so it should work while paused
      await expect(marketplace.connect(creator).delistListing(1)).to.not.be
        .reverted;
    });
  });
});
