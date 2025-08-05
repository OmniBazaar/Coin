const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniMarketplace", function () {
  let marketplace;
  let core;
  let owner, seller, buyer, seller2;
  
  beforeEach(async function () {
    [owner, seller, buyer, seller2] = await ethers.getSigners();
    
    // Deploy OmniCoin
    const Token = await ethers.getContractFactory("OmniCoin");
    const token = await Token.deploy();
    await token.initialize();
    
    // Deploy OmniCore with all required constructor arguments
    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await OmniCore.deploy(owner.address, token.target, owner.address, owner.address);
    
    // Deploy OmniMarketplace
    const OmniMarketplace = await ethers.getContractFactory("OmniMarketplace");
    marketplace = await OmniMarketplace.deploy(core.target);
  });
  
  describe("Listing Management", function () {
    it("Should create listing", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      const isPrivate = false;
      
      const tx = await marketplace.connect(seller).createListing(dataHash, isPrivate);
      const receipt = await tx.wait();
      
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      );
      
      expect(event).to.not.be.undefined;
      const listingId = event.args.listingId;
      expect(listingId).to.equal(1);
      
      const listing = await marketplace.listings(listingId);
      expect(listing.seller).to.equal(seller.address);
      expect(listing.dataHash).to.equal(dataHash);
      expect(listing.isActive).to.be.true;
      expect(listing.isPrivate).to.be.false;
    });
    
    it("Should create private listing", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Private Product"));
      const isPrivate = true;
      
      const tx = await marketplace.connect(seller).createListing(dataHash, isPrivate);
      const receipt = await tx.wait();
      
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      const listing = await marketplace.listings(listingId);
      expect(listing.isPrivate).to.be.true;
    });
    
    it("Should track listing count", async function () {
      expect(await marketplace.listingCount()).to.equal(0);
      
      const dataHash1 = ethers.keccak256(ethers.toUtf8Bytes("Product 1"));
      await marketplace.connect(seller).createListing(dataHash1, false);
      expect(await marketplace.listingCount()).to.equal(1);
      
      const dataHash2 = ethers.keccak256(ethers.toUtf8Bytes("Product 2"));
      await marketplace.connect(seller).createListing(dataHash2, true);
      expect(await marketplace.listingCount()).to.equal(2);
    });
    
    it("Should track active listings per seller", async function () {
      const dataHash1 = ethers.keccak256(ethers.toUtf8Bytes("Product 1"));
      const dataHash2 = ethers.keccak256(ethers.toUtf8Bytes("Product 2"));
      
      expect(await marketplace.activeListingsCount(seller.address)).to.equal(0);
      
      await marketplace.connect(seller).createListing(dataHash1, false);
      expect(await marketplace.activeListingsCount(seller.address)).to.equal(1);
      
      await marketplace.connect(seller).createListing(dataHash2, false);
      expect(await marketplace.activeListingsCount(seller.address)).to.equal(2);
    });
    
    it("Should reject invalid data hash", async function () {
      await expect(
        marketplace.connect(seller).createListing(ethers.ZeroHash, false)
      ).to.be.revertedWithCustomError(marketplace, "InvalidDataHash");
    });
    
    it("Should update listing data hash", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      const newDataHash = ethers.keccak256(ethers.toUtf8Bytes("Updated Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      await marketplace.connect(seller).updateListing(listingId, newDataHash);
      
      const listing = await marketplace.listings(listingId);
      expect(listing.dataHash).to.equal(newDataHash);
    });
    
    it("Should only allow seller to update their listing", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      const newDataHash = ethers.keccak256(ethers.toUtf8Bytes("Updated Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      await expect(
        marketplace.connect(buyer).updateListing(listingId, newDataHash)
      ).to.be.revertedWithCustomError(marketplace, "Unauthorized");
    });
    
    it("Should deactivate listing", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      expect(await marketplace.activeListingsCount(seller.address)).to.equal(1);
      
      await marketplace.connect(seller).deactivateListing(listingId);
      
      const listing = await marketplace.listings(listingId);
      expect(listing.isActive).to.be.false;
      
      expect(await marketplace.activeListingsCount(seller.address)).to.equal(0);
    });
    
    it("Should prevent updating inactive listing", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      const newDataHash = ethers.keccak256(ethers.toUtf8Bytes("Updated Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      await marketplace.connect(seller).deactivateListing(listingId);
      
      await expect(
        marketplace.connect(seller).updateListing(listingId, newDataHash)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotActive");
    });
  });
  
  describe("Purchase Events", function () {
    it("Should record purchase event", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      // In the simplified marketplace, actual purchases happen off-chain
      // Only the event is emitted on-chain for indexing
      const escrowId = 12345; // Mock escrow ID from off-chain
      
      await expect(
        marketplace.connect(buyer).recordPurchase(listingId, escrowId)
      ).to.emit(marketplace, "PurchaseInitiated")
        .withArgs(listingId, buyer.address, escrowId);
    });
    
    it("Should allow anyone to record purchase", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      // In production, this would be restricted to escrow contract
      // For now, anyone can record a purchase
      await expect(
        marketplace.connect(buyer).recordPurchase(listingId, 12345)
      ).to.emit(marketplace, "PurchaseInitiated");
    });
    
    it("Should prevent purchase event for inactive listing", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      await marketplace.connect(seller).deactivateListing(listingId);
      
      await expect(
        marketplace.connect(buyer).recordPurchase(listingId, 12345)
      ).to.be.revertedWithCustomError(marketplace, "ListingNotActive");
    });
  });
  
  describe("Events", function () {
    it("Should emit ListingCreated event", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      const isPrivate = false;
      
      await expect(marketplace.connect(seller).createListing(dataHash, isPrivate))
        .to.emit(marketplace, "ListingCreated")
        .withArgs(1, seller.address, dataHash, isPrivate);
    });
    
    it("Should emit ListingUpdated event", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      const newDataHash = ethers.keccak256(ethers.toUtf8Bytes("Updated Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      await expect(marketplace.connect(seller).updateListing(listingId, newDataHash))
        .to.emit(marketplace, "ListingUpdated")
        .withArgs(listingId, newDataHash);
    });
    
    it("Should emit ListingDeactivated event", async function () {
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("Test Product"));
      
      const tx = await marketplace.connect(seller).createListing(dataHash, false);
      const receipt = await tx.wait();
      const listingId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ListingCreated"
      ).args.listingId;
      
      await expect(marketplace.connect(seller).deactivateListing(listingId))
        .to.emit(marketplace, "ListingDeactivated")
        .withArgs(listingId);
    });
  });
  
  describe("Integration", function () {
    it("Should support multiple sellers", async function () {
      const dataHash1 = ethers.keccak256(ethers.toUtf8Bytes("Seller1 Product"));
      const dataHash2 = ethers.keccak256(ethers.toUtf8Bytes("Seller2 Product"));
      
      await marketplace.connect(seller).createListing(dataHash1, false);
      await marketplace.connect(seller2).createListing(dataHash2, true);
      
      expect(await marketplace.listingCount()).to.equal(2);
      expect(await marketplace.activeListingsCount(seller.address)).to.equal(1);
      expect(await marketplace.activeListingsCount(seller2.address)).to.equal(1);
      
      const listing1 = await marketplace.listings(1);
      const listing2 = await marketplace.listings(2);
      
      expect(listing1.seller).to.equal(seller.address);
      expect(listing2.seller).to.equal(seller2.address);
      expect(listing1.isPrivate).to.be.false;
      expect(listing2.isPrivate).to.be.true;
    });
  });
});