const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniNFTMarketplace", function () {
  async function deployMarketplaceFixture() {
    const [owner, seller, buyer, feeRecipient, unauthorized] = await ethers.getSigners();

    // Deploy actual OmniCoinRegistry
    const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await OmniCoinRegistry.deploy(await owner.getAddress());
    await registry.waitForDeployment();

    // Deploy actual OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy(await registry.getAddress());
    await omniCoin.waitForDeployment();

    // Deploy actual ListingNFT
    const ListingNFT = await ethers.getContractFactory("ListingNFT");
    const nftContract = await ListingNFT.deploy(
      await registry.getAddress(),
      await owner.getAddress()
    );
    await nftContract.waitForDeployment();

    // Deploy PrivacyFeeManager (needed for marketplace)
    const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
    const cotiToken = await StandardERC20Test.deploy();
    await cotiToken.waitForDeployment();

    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await omniCoin.getAddress(),
      await cotiToken.getAddress(),
      await owner.getAddress(), // DEX router
      await owner.getAddress()
    );
    await privacyFeeManager.waitForDeployment();

    // Deploy OmniNFTMarketplace
    const OmniNFTMarketplace = await ethers.getContractFactory("OmniNFTMarketplace");
    const marketplace = await OmniNFTMarketplace.deploy(
      await omniCoin.getAddress(),
      await registry.getAddress(),
      await privacyFeeManager.getAddress()
    );
    await marketplace.waitForDeployment();

    // Set up registry
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
      await omniCoin.getAddress()
    );
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("LISTING_NFT")),
      await nftContract.getAddress()
    );
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("NFT_MARKETPLACE")),
      await marketplace.getAddress()
    );

    // Set up fee distribution
    await marketplace.setFeeDistribution(
      await feeRecipient.getAddress(),
      await owner.getAddress(), // development fund
      7000, // 70% validators
      2000, // 20% treasury
      1000  // 10% development
    );

    // Grant necessary roles
    await privacyFeeManager.grantRole(
      await privacyFeeManager.FEE_MANAGER_ROLE(),
      await marketplace.getAddress()
    );

    // Mint tokens and NFTs for testing
    await omniCoin.mint(await seller.getAddress(), ethers.parseUnits("10000", 6));
    await omniCoin.mint(await buyer.getAddress(), ethers.parseUnits("10000", 6));

    // Mint NFTs to seller
    const tokenIds = [];
    for (let i = 1; i <= 3; i++) {
      await nftContract.mint(await seller.getAddress(), `https://example.com/token/${i}`);
      const currentTokenId = await nftContract.currentTokenId();
      tokenIds.push(currentTokenId);
      await nftContract.connect(seller).approve(await marketplace.getAddress(), currentTokenId);
    }

    // Approve marketplace
    await omniCoin.connect(seller).approve(await marketplace.getAddress(), ethers.MaxUint256);
    await omniCoin.connect(buyer).approve(await marketplace.getAddress(), ethers.MaxUint256);

    return {
      marketplace,
      omniCoin,
      nftContract,
      privacyFeeManager,
      registry,
      owner,
      seller,
      buyer,
      feeRecipient,
      unauthorized,
      tokenIds
    };
  }

  describe("Deployment", function () {
    it("Should set correct initial values", async function () {
      const { marketplace, omniCoin, registry } = await loadFixture(deployMarketplaceFixture);

      expect(await marketplace.paymentToken()).to.equal(await omniCoin.getAddress());
      expect(await marketplace.registry()).to.equal(await registry.getAddress());
      expect(await marketplace.marketplaceFee()).to.equal(250); // 2.5%
      expect(await marketplace.listingCounter()).to.equal(0);
      expect(await marketplace.auctionCounter()).to.equal(0);
      expect(await marketplace.offerCounter()).to.equal(0);
    });
  });

  describe("Listing Management", function () {
    it("Should create a fixed price listing", async function () {
      const { marketplace, nftContract, seller, tokenIds } = await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[0];
      const price = ethers.parseUnits("100", 6);
      const duration = 86400; // 24 hours

      await expect(
        marketplace.connect(seller).createListing(
          await nftContract.getAddress(),
          tokenId,
          price,
          duration
        )
      ).to.emit(marketplace, "ListingCreated")
        .withArgs(1, await seller.getAddress(), await nftContract.getAddress(), tokenId, price, false);

      const listing = await marketplace.getListing(1);
      expect(listing.seller).to.equal(await seller.getAddress());
      expect(listing.nftContract).to.equal(await nftContract.getAddress());
      expect(listing.tokenId).to.equal(tokenId);
      expect(listing.price).to.equal(price);
      expect(listing.isActive).to.be.true;
    });

    it("Should buy an item from listing", async function () {
      const { marketplace, nftContract, omniCoin, seller, buyer, tokenIds } = 
        await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[0];
      const price = ethers.parseUnits("100", 6);

      // Create listing
      await marketplace.connect(seller).createListing(
        await nftContract.getAddress(),
        tokenId,
        price,
        86400
      );

      const sellerBalanceBefore = await omniCoin.balanceOf(await seller.getAddress());
      const buyerBalanceBefore = await omniCoin.balanceOf(await buyer.getAddress());

      // Buy item
      await expect(
        marketplace.connect(buyer).buyItem(1)
      ).to.emit(marketplace, "ItemSold")
        .withArgs(1, await seller.getAddress(), await buyer.getAddress(), price, false);

      // Check NFT ownership transferred
      expect(await nftContract.ownerOf(tokenId)).to.equal(await buyer.getAddress());

      // Check payment (minus marketplace fee)
      const marketplaceFee = price * 250n / 10000n; // 2.5%
      const sellerReceived = price - marketplaceFee;
      
      expect(await omniCoin.balanceOf(await seller.getAddress()))
        .to.equal(sellerBalanceBefore + sellerReceived);
      expect(await omniCoin.balanceOf(await buyer.getAddress()))
        .to.equal(buyerBalanceBefore - price);
    });

    it("Should cancel a listing", async function () {
      const { marketplace, nftContract, seller, tokenIds } = await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[0];
      
      // Create listing
      await marketplace.connect(seller).createListing(
        await nftContract.getAddress(),
        tokenId,
        ethers.parseUnits("100", 6),
        86400
      );

      // Cancel listing
      await expect(
        marketplace.connect(seller).cancelListing(1)
      ).to.emit(marketplace, "ListingCancelled")
        .withArgs(1, await seller.getAddress());

      // Check listing is inactive
      const listing = await marketplace.getListing(1);
      expect(listing.isActive).to.be.false;

      // NFT should be returned to seller
      expect(await nftContract.ownerOf(tokenId)).to.equal(await seller.getAddress());
    });
  });

  describe("Auction System", function () {
    it("Should create an auction", async function () {
      const { marketplace, nftContract, seller, tokenIds } = await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[1];
      const startingPrice = ethers.parseUnits("50", 6);
      const reservePrice = ethers.parseUnits("200", 6);
      const duration = 86400; // 24 hours

      await expect(
        marketplace.connect(seller).createAuction(
          await nftContract.getAddress(),
          tokenId,
          startingPrice,
          reservePrice,
          duration
        )
      ).to.emit(marketplace, "AuctionCreated")
        .withArgs(1, await seller.getAddress(), await nftContract.getAddress(), tokenId, startingPrice, false);

      const auction = await marketplace.getAuction(1);
      expect(auction.seller).to.equal(await seller.getAddress());
      expect(auction.startingPrice).to.equal(startingPrice);
      expect(auction.reservePrice).to.equal(reservePrice);
      expect(auction.highestBid).to.equal(0);
      expect(auction.isActive).to.be.true;
    });

    it("Should place bids on auction", async function () {
      const { marketplace, nftContract, seller, buyer, tokenIds } = await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[1];
      
      // Create auction
      await marketplace.connect(seller).createAuction(
        await nftContract.getAddress(),
        tokenId,
        ethers.parseUnits("50", 6),
        ethers.parseUnits("200", 6),
        86400
      );

      // Place first bid
      const bid1 = ethers.parseUnits("60", 6);
      await expect(
        marketplace.connect(buyer).placeBid(1, bid1)
      ).to.emit(marketplace, "BidPlaced")
        .withArgs(1, await buyer.getAddress(), bid1, false);

      // Check auction state
      const auction = await marketplace.getAuction(1);
      expect(auction.highestBidder).to.equal(await buyer.getAddress());
      expect(auction.highestBid).to.equal(bid1);
    });

    it("Should end auction and transfer NFT", async function () {
      const { marketplace, nftContract, omniCoin, seller, buyer, tokenIds } = 
        await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[1];
      const reservePrice = ethers.parseUnits("200", 6);
      
      // Create auction with short duration
      await marketplace.connect(seller).createAuction(
        await nftContract.getAddress(),
        tokenId,
        ethers.parseUnits("50", 6),
        reservePrice,
        1 // 1 second duration
      );

      // Place bid above reserve
      await marketplace.connect(buyer).placeBid(1, reservePrice);

      // Wait for auction to end
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      const sellerBalanceBefore = await omniCoin.balanceOf(await seller.getAddress());

      // End auction
      await expect(
        marketplace.endAuction(1)
      ).to.emit(marketplace, "AuctionEnded")
        .withArgs(1, await buyer.getAddress(), reservePrice);

      // Check NFT transferred to winner
      expect(await nftContract.ownerOf(tokenId)).to.equal(await buyer.getAddress());

      // Check seller received payment (minus fee)
      const marketplaceFee = reservePrice * 250n / 10000n;
      const sellerReceived = reservePrice - marketplaceFee;
      
      expect(await omniCoin.balanceOf(await seller.getAddress()))
        .to.equal(sellerBalanceBefore + sellerReceived);
    });
  });

  describe("Offer System", function () {
    it("Should make an offer on NFT", async function () {
      const { marketplace, nftContract, buyer, tokenIds } = await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[2];
      const offerAmount = ethers.parseUnits("80", 6);
      const expiry = Math.floor(Date.now() / 1000) + 86400;

      await expect(
        marketplace.connect(buyer).makeOffer(
          await nftContract.getAddress(),
          tokenId,
          offerAmount,
          expiry
        )
      ).to.emit(marketplace, "OfferMade")
        .withArgs(1, await buyer.getAddress(), await nftContract.getAddress(), tokenId, offerAmount, false);

      const offer = await marketplace.getOffer(1);
      expect(offer.offeror).to.equal(await buyer.getAddress());
      expect(offer.amount).to.equal(offerAmount);
      expect(offer.isActive).to.be.true;
    });

    it("Should accept an offer", async function () {
      const { marketplace, nftContract, omniCoin, seller, buyer, tokenIds } = 
        await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[2];
      const offerAmount = ethers.parseUnits("80", 6);
      const expiry = Math.floor(Date.now() / 1000) + 86400;

      // Make offer
      await marketplace.connect(buyer).makeOffer(
        await nftContract.getAddress(),
        tokenId,
        offerAmount,
        expiry
      );

      const sellerBalanceBefore = await omniCoin.balanceOf(await seller.getAddress());
      const buyerBalanceBefore = await omniCoin.balanceOf(await buyer.getAddress());

      // Accept offer
      await expect(
        marketplace.connect(seller).acceptOffer(1)
      ).to.emit(marketplace, "OfferAccepted")
        .withArgs(1, await seller.getAddress(), await buyer.getAddress(), offerAmount);

      // Check NFT transferred
      expect(await nftContract.ownerOf(tokenId)).to.equal(await buyer.getAddress());

      // Check payment
      const marketplaceFee = offerAmount * 250n / 10000n;
      const sellerReceived = offerAmount - marketplaceFee;
      
      expect(await omniCoin.balanceOf(await seller.getAddress()))
        .to.equal(sellerBalanceBefore + sellerReceived);
      expect(await omniCoin.balanceOf(await buyer.getAddress()))
        .to.equal(buyerBalanceBefore - offerAmount);
    });

    it("Should cancel an offer", async function () {
      const { marketplace, nftContract, buyer, tokenIds } = await loadFixture(deployMarketplaceFixture);

      const tokenId = tokenIds[2];
      
      // Make offer
      await marketplace.connect(buyer).makeOffer(
        await nftContract.getAddress(),
        tokenId,
        ethers.parseUnits("80", 6),
        Math.floor(Date.now() / 1000) + 86400
      );

      // Cancel offer
      await expect(
        marketplace.connect(buyer).cancelOffer(1)
      ).to.emit(marketplace, "OfferCancelled")
        .withArgs(1, await buyer.getAddress());

      // Check offer is inactive
      const offer = await marketplace.getOffer(1);
      expect(offer.isActive).to.be.false;
    });
  });

  describe("Fee Management", function () {
    it("Should update marketplace fee", async function () {
      const { marketplace, owner } = await loadFixture(deployMarketplaceFixture);

      const newFee = 300; // 3%
      
      await expect(
        marketplace.connect(owner).setMarketplaceFee(newFee)
      ).to.emit(marketplace, "MarketplaceFeeUpdated")
        .withArgs(250, newFee);

      expect(await marketplace.marketplaceFee()).to.equal(newFee);
    });

    it("Should distribute accumulated fees", async function () {
      const { marketplace, nftContract, omniCoin, seller, buyer, feeRecipient, owner, tokenIds } = 
        await loadFixture(deployMarketplaceFixture);

      // Execute a sale to generate fees
      const price = ethers.parseUnits("1000", 6);
      await marketplace.connect(seller).createListing(
        await nftContract.getAddress(),
        tokenIds[0],
        price,
        86400
      );
      await marketplace.connect(buyer).buyItem(1);

      // Check accumulated fees
      const accumulatedFees = await marketplace.accumulatedFees();
      expect(accumulatedFees).to.equal(price * 250n / 10000n);

      const treasuryBefore = await omniCoin.balanceOf(await feeRecipient.getAddress());
      const developmentBefore = await omniCoin.balanceOf(await owner.getAddress());

      // Distribute fees
      await expect(
        marketplace.connect(owner).distributeFees()
      ).to.emit(marketplace, "FeesDistributed");

      // Check distribution (20% treasury, 10% development, 70% to validators - not checked here)
      const treasuryAfter = await omniCoin.balanceOf(await feeRecipient.getAddress());
      const developmentAfter = await omniCoin.balanceOf(await owner.getAddress());

      const treasuryReceived = treasuryAfter - treasuryBefore;
      const developmentReceived = developmentAfter - developmentBefore;

      expect(treasuryReceived).to.equal(accumulatedFees * 2000n / 10000n);
      expect(developmentReceived).to.equal(accumulatedFees * 1000n / 10000n);
    });
  });

  describe("Security", function () {
    it("Should prevent unauthorized operations", async function () {
      const { marketplace, nftContract, unauthorized, tokenIds } = await loadFixture(deployMarketplaceFixture);

      // Cannot update fees without admin role
      await expect(
        marketplace.connect(unauthorized).setMarketplaceFee(500)
      ).to.be.revertedWithCustomError(marketplace, "AccessControlUnauthorizedAccount");

      // Cannot distribute fees without admin role
      await expect(
        marketplace.connect(unauthorized).distributeFees()
      ).to.be.revertedWithCustomError(marketplace, "AccessControlUnauthorizedAccount");
    });

    it("Should handle pause functionality", async function () {
      const { marketplace, nftContract, owner, seller, tokenIds } = await loadFixture(deployMarketplaceFixture);

      // Pause marketplace
      await marketplace.connect(owner).pause();

      // Cannot create listing when paused
      await expect(
        marketplace.connect(seller).createListing(
          await nftContract.getAddress(),
          tokenIds[0],
          ethers.parseUnits("100", 6),
          86400
        )
      ).to.be.revertedWithCustomError(marketplace, "EnforcedPause");

      // Unpause
      await marketplace.connect(owner).unpause();

      // Can create listing again
      await expect(
        marketplace.connect(seller).createListing(
          await nftContract.getAddress(),
          tokenIds[0],
          ethers.parseUnits("100", 6),
          86400
        )
      ).to.not.be.reverted;
    });
  });
});