const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniNFTMarketplace Privacy Functions", function () {
  // Test fixture
  async function deployMarketplaceFixture() {
    const [owner, seller, buyer, bidder1, bidder2, treasury, development] = await ethers.getSigners();

    // Deploy actual OmniCoinRegistry first
    const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await OmniCoinRegistry.deploy(await owner.getAddress());
    await registry.waitForDeployment();

    // Deploy actual OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniToken = await OmniCoin.deploy(await registry.getAddress());
    await omniToken.waitForDeployment();

    // For COTI token, use StandardERC20Test
    const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
    const cotiToken = await StandardERC20Test.deploy();
    await cotiToken.waitForDeployment();

    // Deploy actual ListingNFT
    const ListingNFT = await ethers.getContractFactory("ListingNFT");
    const nftCollection = await ListingNFT.deploy(
        await registry.getAddress(),
        await owner.getAddress()
    );
    await nftCollection.waitForDeployment();

    // Set up registry
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
      await omniToken.getAddress()
    );
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("LISTING_NFT")),
      await nftCollection.getAddress()
    );
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
      await treasury.getAddress()
    );

    // Deploy PrivacyFeeManager
    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await omniToken.getAddress(),
      await cotiToken.getAddress(),
      await owner.getAddress(), // DEX router address
      await owner.getAddress()
    );
    await privacyFeeManager.waitForDeployment();

    // Deploy OmniNFTMarketplace
    const OmniNFTMarketplace = await ethers.getContractFactory("OmniNFTMarketplace");
    const marketplace = await OmniNFTMarketplace.deploy(
      await omniToken.getAddress(),
      await registry.getAddress(),
      await privacyFeeManager.getAddress()
    );
    await marketplace.waitForDeployment();

    // Set up fee distribution
    await marketplace.setFeeDistribution(
      await treasury.getAddress(),
      await development.getAddress(),
      7000, // 70% validators
      2000, // 20% treasury
      1000  // 10% development
    );

    // Grant necessary roles
    await privacyFeeManager.grantRole(await privacyFeeManager.FEE_MANAGER_ROLE(), await marketplace.getAddress());

    // Mint tokens
    const mintAmount = ethers.parseUnits("100000", 6);
    await omniToken.mint(await seller.getAddress(), mintAmount);
    await omniToken.mint(await buyer.getAddress(), mintAmount);
    await omniToken.mint(await bidder1.getAddress(), mintAmount);
    await omniToken.mint(await bidder2.getAddress(), mintAmount);

    // Mint NFTs to seller and get token IDs
    const tokenIds = [];
    for (let i = 1; i <= 5; i++) {
      await nftCollection.mint(await seller.getAddress(), "https://example.com/token/" + i);
      const currentTokenId = await nftCollection.currentTokenId();
      tokenIds.push(currentTokenId);
      await nftCollection.connect(seller).approve(await marketplace.getAddress(), currentTokenId);
    }

    // Approve marketplace and fee manager
    await omniToken.connect(seller).approve(await marketplace.getAddress(), ethers.MaxUint256);
    await omniToken.connect(buyer).approve(await marketplace.getAddress(), ethers.MaxUint256);
    await omniToken.connect(bidder1).approve(await marketplace.getAddress(), ethers.MaxUint256);
    await omniToken.connect(bidder2).approve(await marketplace.getAddress(), ethers.MaxUint256);
    
    await omniToken.connect(seller).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(buyer).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(bidder1).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);
    await omniToken.connect(bidder2).approve(await privacyFeeManager.getAddress(), ethers.MaxUint256);

    // Note: Privacy preferences would be set on actual PrivateOmniCoin with MPC
    // For testing with standard tokens, we skip this step

    return {
      marketplace,
      omniToken,
      nftCollection,
      privacyFeeManager,
      registry,
      owner,
      seller,
      buyer,
      bidder1,
      bidder2,
      treasury,
      development,
      tokenIds
    };
  }

  describe("Public NFT Listings (No Privacy)", function () {
    it("Should create public listing without privacy fees", async function () {
      const { marketplace, nftCollection, seller } = await loadFixture(deployMarketplaceFixture);

      const tokenId = 1;
      const price = ethers.parseUnits("1000", 6);
      const duration = 86400; // 24 hours

      // Create public listing
      await expect(marketplace.connect(seller).createListing(
        await nftCollection.getAddress(),
        tokenId,
        price,
        duration
      )).to.emit(marketplace, "ListingCreated")
        .withArgs(1, seller.address, await nftCollection.getAddress(), tokenId, price, false);

      // Verify listing details
      const listing = await marketplace.getListing(1);
      expect(listing.seller).to.equal(seller.address);
      expect(listing.price).to.equal(price);
      expect(listing.isPrivate).to.be.false;
    });

    it("Should handle public purchases", async function () {
      const { marketplace, nftCollection, omniToken, seller, buyer } = await loadFixture(deployMarketplaceFixture);

      // Create listing
      const tokenId = 1;
      const price = ethers.parseUnits("1000", 6);
      await marketplace.connect(seller).createListing(
        await nftCollection.getAddress(),
        tokenId,
        price,
        86400
      );

      const buyerBalanceBefore = await omniToken.balanceOf(buyer.address);
      const sellerBalanceBefore = await omniToken.balanceOf(seller.address);

      // Buy item publicly
      await expect(marketplace.connect(buyer).buyItem(1))
        .to.emit(marketplace, "ItemSold")
        .withArgs(1, seller.address, buyer.address, price, false);

      // Verify NFT ownership transferred
      expect(await nftCollection.ownerOf(tokenId)).to.equal(buyer.address);

      // Verify payment (minus marketplace fee)
      const buyerBalanceAfter = await omniToken.balanceOf(buyer.address);
      const sellerBalanceAfter = await omniToken.balanceOf(seller.address);
      
      expect(buyerBalanceBefore - buyerBalanceAfter).to.equal(price);
      expect(sellerBalanceAfter - sellerBalanceBefore).to.be.lt(price); // Seller receives less due to fees
    });
  });

  describe("Private NFT Listings (With Privacy)", function () {
    it("Should create private listing with privacy credits", async function () {
      const { marketplace, nftCollection, privacyFeeManager, seller, owner } = 
        await loadFixture(deployMarketplaceFixture);

      // Enable MPC
      await marketplace.connect(owner).setMpcAvailability(true);

      // Pre-deposit privacy credits
      await privacyFeeManager.connect(seller).depositPrivacyCredits(ethers.parseUnits("1000", 6));

      const tokenId = 2;
      const price = ethers.parseUnits("5000", 6);
      const duration = 86400;

      // Calculate expected privacy fee
      const operationType = ethers.keccak256(ethers.toUtf8Bytes("NFT_LISTING"));
      const expectedFee = await privacyFeeManager.calculatePrivacyFee(operationType, price);

      const creditsBefore = await privacyFeeManager.getPrivacyCredits(seller.address);

      // Create encrypted price (simulated)
      const encryptedPrice = { data: ethers.hexlify(ethers.randomBytes(32)) };

      // Create private listing
      await expect(marketplace.connect(seller).createListingWithPrivacy(
        await nftCollection.getAddress(),
        tokenId,
        encryptedPrice,
        duration,
        true // use privacy
      )).to.emit(marketplace, "ListingCreated")
        .withArgs(1, seller.address, await nftCollection.getAddress(), tokenId, price, true);

      // Verify privacy credits deducted
      const creditsAfter = await privacyFeeManager.getPrivacyCredits(seller.address);
      expect(creditsBefore - creditsAfter).to.equal(expectedFee);

      // Verify listing is private
      const listing = await marketplace.getListing(1);
      expect(listing.isPrivate).to.be.true;
    });

    it("Should handle private purchases", async function () {
      const { marketplace, nftCollection, privacyFeeManager, seller, buyer, owner } = 
        await loadFixture(deployMarketplaceFixture);

      await marketplace.connect(owner).setMpcAvailability(true);

      // Pre-deposit credits for both parties
      await privacyFeeManager.connect(seller).depositPrivacyCredits(ethers.parseUnits("5000", 6));
      await privacyFeeManager.connect(buyer).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      // Create private listing
      const tokenId = 2;
      const price = ethers.parseUnits("2000", 6);
      const encryptedPrice = { data: ethers.hexlify(ethers.randomBytes(32)) };

      await marketplace.connect(seller).createListingWithPrivacy(
        await nftCollection.getAddress(),
        tokenId,
        encryptedPrice,
        86400,
        true
      );

      const buyerCreditsBefore = await privacyFeeManager.getPrivacyCredits(buyer.address);

      // Buy item privately
      await expect(marketplace.connect(buyer).buyItemWithPrivacy(1, true))
        .to.emit(marketplace, "ItemSold")
        .withArgs(1, seller.address, buyer.address, price, true);

      // Verify NFT transferred
      expect(await nftCollection.ownerOf(tokenId)).to.equal(buyer.address);

      // Verify privacy fee deducted from buyer
      const buyerCreditsAfter = await privacyFeeManager.getPrivacyCredits(buyer.address);
      expect(buyerCreditsBefore - buyerCreditsAfter).to.be.gt(0);
    });
  });

  describe("Auction System", function () {
    it("Should create public auctions", async function () {
      const { marketplace, nftCollection, seller } = await loadFixture(deployMarketplaceFixture);

      const tokenId = 3;
      const startingPrice = ethers.parseUnits("100", 6);
      const reservePrice = ethers.parseUnits("1000", 6);
      const duration = 86400;

      // Create auction
      await expect(marketplace.connect(seller).createAuction(
        await nftCollection.getAddress(),
        tokenId,
        startingPrice,
        reservePrice,
        duration
      )).to.emit(marketplace, "AuctionCreated")
        .withArgs(1, seller.address, await nftCollection.getAddress(), tokenId, startingPrice, false);

      // Verify auction details
      const auction = await marketplace.getAuction(1);
      expect(auction.seller).to.equal(seller.address);
      expect(auction.highestBid).to.equal(0);
      expect(auction.isPrivate).to.be.false;
    });

    it("Should handle public bidding", async function () {
      const { marketplace, nftCollection, seller, bidder1, bidder2 } = await loadFixture(deployMarketplaceFixture);

      // Create auction
      const tokenId = 3;
      await marketplace.connect(seller).createAuction(
        await nftCollection.getAddress(),
        tokenId,
        ethers.parseUnits("100", 6),
        ethers.parseUnits("1000", 6),
        86400
      );

      // First bid
      const bid1 = ethers.parseUnits("200", 6);
      await expect(marketplace.connect(bidder1).placeBid(1, bid1))
        .to.emit(marketplace, "BidPlaced")
        .withArgs(1, bidder1.address, bid1, false);

      // Higher bid
      const bid2 = ethers.parseUnits("300", 6);
      await expect(marketplace.connect(bidder2).placeBid(1, bid2))
        .to.emit(marketplace, "BidPlaced")
        .withArgs(1, bidder2.address, bid2, false);

      // Verify highest bidder
      const auction = await marketplace.getAuction(1);
      expect(auction.highestBidder).to.equal(bidder2.address);
      expect(auction.highestBid).to.equal(bid2);
    });

    it("Should create private auctions with credits", async function () {
      const { marketplace, nftCollection, privacyFeeManager, seller, owner } = 
        await loadFixture(deployMarketplaceFixture);

      await marketplace.connect(owner).setMpcAvailability(true);

      // Pre-deposit credits
      await privacyFeeManager.connect(seller).depositPrivacyCredits(ethers.parseUnits("1000", 6));

      const tokenId = 4;
      const encryptedStartingPrice = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const encryptedReservePrice = { data: ethers.hexlify(ethers.randomBytes(32)) };

      // Create private auction
      await expect(marketplace.connect(seller).createAuctionWithPrivacy(
        await nftCollection.getAddress(),
        tokenId,
        encryptedStartingPrice,
        encryptedReservePrice,
        86400,
        true
      )).to.emit(marketplace, "AuctionCreated");
    });

    it("Should handle private bidding", async function () {
      const { marketplace, nftCollection, privacyFeeManager, seller, bidder1, owner } = 
        await loadFixture(deployMarketplaceFixture);

      await marketplace.connect(owner).setMpcAvailability(true);

      // Setup
      await privacyFeeManager.connect(seller).depositPrivacyCredits(ethers.parseUnits("1000", 6));
      await privacyFeeManager.connect(bidder1).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      // Create auction
      const tokenId = 4;
      const encryptedStartingPrice = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const encryptedReservePrice = { data: ethers.hexlify(ethers.randomBytes(32)) };

      await marketplace.connect(seller).createAuctionWithPrivacy(
        await nftCollection.getAddress(),
        tokenId,
        encryptedStartingPrice,
        encryptedReservePrice,
        86400,
        true
      );

      // Place private bid
      const encryptedBid = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const bidderCreditsBefore = await privacyFeeManager.getPrivacyCredits(bidder1.address);

      await expect(marketplace.connect(bidder1).placeBidWithPrivacy(1, encryptedBid, true))
        .to.emit(marketplace, "BidPlaced");

      // Verify privacy credits deducted
      const bidderCreditsAfter = await privacyFeeManager.getPrivacyCredits(bidder1.address);
      expect(bidderCreditsBefore - bidderCreditsAfter).to.be.gt(0);
    });
  });

  describe("Offer System", function () {
    it("Should make public offers", async function () {
      const { marketplace, nftCollection, buyer } = await loadFixture(deployMarketplaceFixture);

      const tokenId = 5;
      const offerAmount = ethers.parseUnits("800", 6);
      const expiry = Math.floor(Date.now() / 1000) + 86400;

      // Make offer
      await expect(marketplace.connect(buyer).makeOffer(
        await nftCollection.getAddress(),
        tokenId,
        offerAmount,
        expiry
      )).to.emit(marketplace, "OfferMade")
        .withArgs(1, buyer.address, await nftCollection.getAddress(), tokenId, offerAmount, false);

      // Verify offer
      const offer = await marketplace.getOffer(1);
      expect(offer.offeror).to.equal(buyer.address);
      expect(offer.amount).to.equal(offerAmount);
      expect(offer.isPrivate).to.be.false;
    });

    it("Should make private offers with credits", async function () {
      const { marketplace, nftCollection, privacyFeeManager, buyer, owner } = 
        await loadFixture(deployMarketplaceFixture);

      await marketplace.connect(owner).setMpcAvailability(true);

      // Pre-deposit credits
      await privacyFeeManager.connect(buyer).depositPrivacyCredits(ethers.parseUnits("2000", 6));

      const tokenId = 5;
      const encryptedAmount = { data: ethers.hexlify(ethers.randomBytes(32)) };
      const expiry = Math.floor(Date.now() / 1000) + 86400;

      const creditsBefore = await privacyFeeManager.getPrivacyCredits(buyer.address);

      // Make private offer
      await expect(marketplace.connect(buyer).makeOfferWithPrivacy(
        await nftCollection.getAddress(),
        tokenId,
        encryptedAmount,
        expiry,
        true
      )).to.emit(marketplace, "OfferMade");

      // Verify privacy credits deducted
      const creditsAfter = await privacyFeeManager.getPrivacyCredits(buyer.address);
      expect(creditsBefore - creditsAfter).to.be.gt(0);
    });

    it("Should accept offers", async function () {
      const { marketplace, nftCollection, omniToken, seller, buyer } = await loadFixture(deployMarketplaceFixture);

      // Buyer makes offer
      const tokenId = 5;
      const offerAmount = ethers.parseUnits("800", 6);
      await marketplace.connect(buyer).makeOffer(
        await nftCollection.getAddress(),
        tokenId,
        offerAmount,
        Math.floor(Date.now() / 1000) + 86400
      );

      // Seller accepts offer
      await expect(marketplace.connect(seller).acceptOffer(1))
        .to.emit(marketplace, "OfferAccepted")
        .withArgs(1, seller.address, buyer.address, offerAmount);

      // Verify NFT transferred
      expect(await nftCollection.ownerOf(tokenId)).to.equal(buyer.address);
    });
  });

  describe("Batch Operations", function () {
    it("Should handle batch listings with mixed privacy", async function () {
      const { marketplace, nftCollection, privacyFeeManager, seller, owner } = 
        await loadFixture(deployMarketplaceFixture);

      // Mint more NFTs
      for (let i = 6; i <= 8; i++) {
        await nftCollection.mint(seller.address, i);
        await nftCollection.connect(seller).approve(await marketplace.getAddress(), i);
      }

      // Pre-deposit credits
      await privacyFeeManager.connect(seller).depositPrivacyCredits(ethers.parseUnits("5000", 6));

      // Create batch listings
      const listings = [
        {
          nftContract: await nftCollection.getAddress(),
          tokenId: 6,
          price: ethers.parseUnits("100", 6),
          duration: 86400,
          usePrivacy: false
        },
        {
          nftContract: await nftCollection.getAddress(),
          tokenId: 7,
          price: ethers.parseUnits("200", 6),
          duration: 86400,
          usePrivacy: true
        },
        {
          nftContract: await nftCollection.getAddress(),
          tokenId: 8,
          price: ethers.parseUnits("300", 6),
          duration: 86400,
          usePrivacy: false
        }
      ];

      await marketplace.connect(owner).setMpcAvailability(true);

      // Execute batch listing
      await expect(marketplace.connect(seller).batchCreateListings(listings))
        .to.emit(marketplace, "BatchListingCompleted");

      // Verify privacy credits only used for private listing
      const stats = await privacyFeeManager.getUserPrivacyStats(seller.address);
      expect(stats.usage).to.be.gte(1);
    });
  });

  describe("Fee Distribution", function () {
    it("Should distribute marketplace fees correctly", async function () {
      const { marketplace, nftCollection, omniToken, seller, buyer, treasury, development, owner } = 
        await loadFixture(deployMarketplaceFixture);

      // Set marketplace fee
      await marketplace.connect(owner).setMarketplaceFee(250); // 2.5%

      // Create and execute sale
      const tokenId = 1;
      const price = ethers.parseUnits("10000", 6);
      
      await marketplace.connect(seller).createListing(
        await nftCollection.getAddress(),
        tokenId,
        price,
        86400
      );

      await marketplace.connect(buyer).buyItem(1);

      // Check accumulated fees
      const accumulatedFees = await marketplace.accumulatedFees();
      expect(accumulatedFees).to.equal(price * 250n / 10000n); // 2.5% of price

      // Distribute fees
      const treasuryBefore = await omniToken.balanceOf(treasury.address);
      const developmentBefore = await omniToken.balanceOf(development.address);

      await marketplace.connect(owner).distributeFees();

      const treasuryAfter = await omniToken.balanceOf(treasury.address);
      const developmentAfter = await omniToken.balanceOf(development.address);

      // Verify distribution (20% treasury, 10% development)
      expect(treasuryAfter).to.be.gt(treasuryBefore);
      expect(developmentAfter).to.be.gt(developmentBefore);
    });
  });

  describe("Edge Cases", function () {
    it("Should handle expired listings", async function () {
      const { marketplace, nftCollection, seller, buyer } = await loadFixture(deployMarketplaceFixture);

      // Create listing with very short duration
      await marketplace.connect(seller).createListing(
        await nftCollection.getAddress(),
        1,
        ethers.parseUnits("1000", 6),
        1 // 1 second
      );

      // Wait for expiry
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      // Try to buy expired listing
      await expect(
        marketplace.connect(buyer).buyItem(1)
      ).to.be.revertedWith("Listing expired");
    });

    it("Should prevent double listing", async function () {
      const { marketplace, nftCollection, seller } = await loadFixture(deployMarketplaceFixture);

      const tokenId = 1;
      const price = ethers.parseUnits("1000", 6);

      // First listing
      await marketplace.connect(seller).createListing(
        await nftCollection.getAddress(),
        tokenId,
        price,
        86400
      );

      // Try to list same NFT again
      await expect(
        marketplace.connect(seller).createListing(
          await nftCollection.getAddress(),
          tokenId,
          price,
          86400
        )
      ).to.be.revertedWith("NFT already listed");
    });

    it("Should respect pause functionality", async function () {
      const { marketplace, nftCollection, seller, owner } = await loadFixture(deployMarketplaceFixture);

      // Pause marketplace
      await marketplace.connect(owner).pause();

      // Try to create listing while paused
      await expect(
        marketplace.connect(seller).createListing(
          await nftCollection.getAddress(),
          1,
          ethers.parseUnits("1000", 6),
          86400
        )
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should handle royalties", async function () {
      const { marketplace, nftCollection, omniToken, seller, buyer, owner } = 
        await loadFixture(deployMarketplaceFixture);

      // Set royalty info (2% to original creator)
      const royaltyRecipient = owner.address;
      const royaltyPercentage = 200; // 2%
      
      await marketplace.connect(owner).setRoyaltyInfo(
        await nftCollection.getAddress(),
        royaltyRecipient,
        royaltyPercentage
      );

      // Create and execute sale
      const tokenId = 1;
      const price = ethers.parseUnits("10000", 6);
      
      await marketplace.connect(seller).createListing(
        await nftCollection.getAddress(),
        tokenId,
        price,
        86400
      );

      const royaltyRecipientBefore = await omniToken.balanceOf(royaltyRecipient);
      
      await marketplace.connect(buyer).buyItem(1);

      const royaltyRecipientAfter = await omniToken.balanceOf(royaltyRecipient);
      
      // Verify royalty paid
      const expectedRoyalty = price * BigInt(royaltyPercentage) / 10000n;
      expect(royaltyRecipientAfter - royaltyRecipientBefore).to.equal(expectedRoyalty);
    });
  });
});