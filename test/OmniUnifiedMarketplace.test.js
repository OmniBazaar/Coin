const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniUnifiedMarketplace", function () {
    let owner, seller1, seller2, buyer1, buyer2, treasury;
    let registry, omniCoin, privateOmniCoin;
    let marketplace, erc721Token, erc1155Token;
    
    // Constants
    const TokenStandard = {
        ERC721: 0,
        ERC1155: 1
    };
    
    const ListingType = {
        FIXED_PRICE: 0,
        AUCTION: 1,
        OFFER_ONLY: 2,
        BUNDLE: 3
    };
    
    const ListingStatus = {
        ACTIVE: 0,
        SOLD: 1,
        CANCELLED: 2,
        EXPIRED: 3
    };
    
    beforeEach(async function () {
        [owner, seller1, seller2, buyer1, buyer2, treasury] = await ethers.getSigners();
        
        // Deploy Registry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(owner.address);
        await registry.deployed();
        
        // Deploy payment tokens
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(registry.address);
        await omniCoin.deployed();
        
        const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
        privateOmniCoin = await PrivateOmniCoin.deploy(registry.address);
        await privateOmniCoin.deployed();
        
        // Register contracts
        await registry.registerContract(
            ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OMNICOIN")),
            omniCoin.address,
            "OmniCoin"
        );
        
        await registry.registerContract(
            ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PRIVATE_OMNICOIN")),
            privateOmniCoin.address,
            "PrivateOmniCoin"
        );
        
        await registry.registerContract(
            ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            treasury.address,
            "Treasury"
        );
        
        // Deploy marketplace
        const Marketplace = await ethers.getContractFactory("OmniUnifiedMarketplace");
        marketplace = await Marketplace.deploy(registry.address);
        await marketplace.deployed();
        
        // Deploy test NFT contracts
        const ERC721 = await ethers.getContractFactory("OmniNFT"); // Assuming this exists
        erc721Token = await ERC721.deploy("Test NFT", "TNFT", registry.address);
        await erc721Token.deployed();
        
        const ERC1155 = await ethers.getContractFactory("OmniERC1155");
        erc1155Token = await ERC1155.deploy(registry.address, "https://test.com/");
        await erc1155Token.deployed();
        
        // Allow NFT contracts in marketplace
        await marketplace.updateContractAllowlist(erc721Token.address, true);
        await marketplace.updateContractAllowlist(erc1155Token.address, true);
        
        // Fund users
        const fundAmount = ethers.utils.parseUnits("10000", 6);
        await omniCoin.transfer(seller1.address, fundAmount);
        await omniCoin.transfer(seller2.address, fundAmount);
        await omniCoin.transfer(buyer1.address, fundAmount);
        await omniCoin.transfer(buyer2.address, fundAmount);
        
        // Approve marketplace for spending
        await omniCoin.connect(buyer1).approve(marketplace.address, ethers.constants.MaxUint256);
        await omniCoin.connect(buyer2).approve(marketplace.address, ethers.constants.MaxUint256);
        await privateOmniCoin.connect(buyer1).approve(marketplace.address, ethers.constants.MaxUint256);
        await privateOmniCoin.connect(buyer2).approve(marketplace.address, ethers.constants.MaxUint256);
    });
    
    describe("ERC-721 Listings", function () {
        let tokenId;
        
        beforeEach(async function () {
            // Mint ERC-721 to seller
            tokenId = 1;
            await erc721Token.mint(seller1.address, tokenId);
            await erc721Token.connect(seller1).approve(marketplace.address, tokenId);
        });
        
        it("Should create ERC-721 listing", async function () {
            const price = ethers.utils.parseUnits("100", 6);
            const duration = 7 * 24 * 60 * 60; // 7 days
            
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC721,
                erc721Token.address,
                tokenId,
                1, // Amount must be 1 for ERC-721
                price,
                false, // Use public token
                ListingType.FIXED_PRICE,
                duration
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Verify listing
            const listing = await marketplace.getListing(listingId);
            expect(listing.standard).to.equal(TokenStandard.ERC721);
            expect(listing.tokenContract).to.equal(erc721Token.address);
            expect(listing.tokenId).to.equal(tokenId);
            expect(listing.amount).to.equal(1);
            expect(listing.pricePerUnit).to.equal(price);
            expect(listing.seller).to.equal(seller1.address);
            expect(listing.status).to.equal(ListingStatus.ACTIVE);
            
            // Verify NFT transferred to marketplace
            expect(await erc721Token.ownerOf(tokenId)).to.equal(marketplace.address);
        });
        
        it("Should allow purchase of ERC-721", async function () {
            const price = ethers.utils.parseUnits("100", 6);
            const duration = 7 * 24 * 60 * 60;
            
            // Create listing
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC721,
                erc721Token.address,
                tokenId,
                1,
                price,
                false,
                ListingType.FIXED_PRICE,
                duration
            );
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Record balances
            const sellerBalanceBefore = await omniCoin.balanceOf(seller1.address);
            const buyerBalanceBefore = await omniCoin.balanceOf(buyer1.address);
            const treasuryBalanceBefore = await omniCoin.balanceOf(treasury.address);
            
            // Purchase
            await expect(
                marketplace.connect(buyer1).purchaseUnified({
                    listingId: listingId,
                    amount: 1,
                    commitment: ethers.constants.HashZero
                })
            ).to.emit(marketplace, "UnifiedPurchase")
            .withArgs(listingId, buyer1.address, 1, price);
            
            // Verify NFT ownership
            expect(await erc721Token.ownerOf(tokenId)).to.equal(buyer1.address);
            
            // Verify payment distribution
            const marketplaceFee = price.mul(250).div(10000); // 2.5%
            const sellerPayment = price.sub(marketplaceFee);
            
            expect(await omniCoin.balanceOf(seller1.address)).to.equal(
                sellerBalanceBefore.add(sellerPayment)
            );
            
            // Verify listing status
            const listing = await marketplace.getListing(listingId);
            expect(listing.status).to.equal(ListingStatus.SOLD);
        });
        
        it("Should reject invalid amount for ERC-721", async function () {
            await expect(
                marketplace.connect(seller1).createUnifiedListing(
                    TokenStandard.ERC721,
                    erc721Token.address,
                    tokenId,
                    2, // Invalid - must be 1
                    ethers.utils.parseUnits("100", 6),
                    false,
                    ListingType.FIXED_PRICE,
                    7 * 24 * 60 * 60
                )
            ).to.be.revertedWith("InvalidAmount");
        });
    });
    
    describe("ERC-1155 Listings", function () {
        let tokenId;
        const tokenAmount = 100;
        
        beforeEach(async function () {
            // Create and mint ERC-1155 tokens
            const tx = await erc1155Token.connect(seller1).createToken(
                tokenAmount,
                0, // FUNGIBLE
                "test-token",
                250 // 2.5% royalty
            );
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenCreated");
            tokenId = event.args.tokenId;
            
            // Approve marketplace
            await erc1155Token.connect(seller1).setApprovalForAll(marketplace.address, true);
        });
        
        it("Should create ERC-1155 listing", async function () {
            const listAmount = 50;
            const pricePerUnit = ethers.utils.parseUnits("10", 6);
            const duration = 7 * 24 * 60 * 60;
            
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC1155,
                erc1155Token.address,
                tokenId,
                listAmount,
                pricePerUnit,
                false,
                ListingType.FIXED_PRICE,
                duration
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Verify listing
            const listing = await marketplace.getListing(listingId);
            expect(listing.standard).to.equal(TokenStandard.ERC1155);
            expect(listing.amount).to.equal(listAmount);
            expect(listing.pricePerUnit).to.equal(pricePerUnit);
            expect(listing.totalPrice).to.equal(pricePerUnit.mul(listAmount));
            
            // Verify tokens escrowed
            expect(await erc1155Token.balanceOf(marketplace.address, tokenId)).to.equal(listAmount);
            expect(await marketplace.escrowedERC1155(erc1155Token.address, tokenId)).to.equal(listAmount);
        });
        
        it("Should allow partial purchase of ERC-1155", async function () {
            const listAmount = 50;
            const pricePerUnit = ethers.utils.parseUnits("10", 6);
            const purchaseAmount = 20;
            
            // Create listing
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC1155,
                erc1155Token.address,
                tokenId,
                listAmount,
                pricePerUnit,
                false,
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Purchase partial amount
            await marketplace.connect(buyer1).purchaseUnified({
                listingId: listingId,
                amount: purchaseAmount,
                commitment: ethers.constants.HashZero
            });
            
            // Verify token transfer
            expect(await erc1155Token.balanceOf(buyer1.address, tokenId)).to.equal(purchaseAmount);
            
            // Verify listing still active with reduced amount
            const listing = await marketplace.getListing(listingId);
            expect(listing.status).to.equal(ListingStatus.ACTIVE);
            expect(listing.amount).to.equal(listAmount - purchaseAmount);
            
            // Verify escrow updated
            expect(await marketplace.escrowedERC1155(erc1155Token.address, tokenId)).to.equal(
                listAmount - purchaseAmount
            );
        });
        
        it("Should handle batch purchases", async function () {
            const pricePerUnit = ethers.utils.parseUnits("5", 6);
            
            // Create listing
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC1155,
                erc1155Token.address,
                tokenId,
                tokenAmount,
                pricePerUnit,
                false,
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Multiple buyers purchase
            await marketplace.connect(buyer1).purchaseUnified({
                listingId: listingId,
                amount: 30,
                commitment: ethers.constants.HashZero
            });
            
            await marketplace.connect(buyer2).purchaseUnified({
                listingId: listingId,
                amount: 40,
                commitment: ethers.constants.HashZero
            });
            
            // Verify balances
            expect(await erc1155Token.balanceOf(buyer1.address, tokenId)).to.equal(30);
            expect(await erc1155Token.balanceOf(buyer2.address, tokenId)).to.equal(40);
            
            // Verify remaining amount
            const listing = await marketplace.getListing(listingId);
            expect(listing.amount).to.equal(30);
        });
    });
    
    describe("Listing Management", function () {
        let erc721ListingId, erc1155ListingId;
        
        beforeEach(async function () {
            // Create ERC-721 listing
            const tokenId = 1;
            await erc721Token.mint(seller1.address, tokenId);
            await erc721Token.connect(seller1).approve(marketplace.address, tokenId);
            
            let tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC721,
                erc721Token.address,
                tokenId,
                1,
                ethers.utils.parseUnits("100", 6),
                false,
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            let receipt = await tx.wait();
            let event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            erc721ListingId = event.args.listingId;
            
            // Create ERC-1155 listing
            tx = await erc1155Token.connect(seller2).createToken(100, 0, "test", 0);
            receipt = await tx.wait();
            event = receipt.events.find(e => e.event === "TokenCreated");
            const erc1155TokenId = event.args.tokenId;
            
            await erc1155Token.connect(seller2).setApprovalForAll(marketplace.address, true);
            
            tx = await marketplace.connect(seller2).createUnifiedListing(
                TokenStandard.ERC1155,
                erc1155Token.address,
                erc1155TokenId,
                50,
                ethers.utils.parseUnits("20", 6),
                false,
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            receipt = await tx.wait();
            event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            erc1155ListingId = event.args.listingId;
        });
        
        it("Should update listing price", async function () {
            const newPrice = ethers.utils.parseUnits("150", 6);
            
            await expect(
                marketplace.connect(seller1).updateListing(
                    erc721ListingId,
                    newPrice,
                    0 // No additional amount for ERC-721
                )
            ).to.emit(marketplace, "ListingUpdated")
            .withArgs(erc721ListingId, newPrice, 1);
            
            const listing = await marketplace.getListing(erc721ListingId);
            expect(listing.pricePerUnit).to.equal(newPrice);
        });
        
        it("Should add more tokens to ERC-1155 listing", async function () {
            const additionalAmount = 25;
            const listing = await marketplace.getListing(erc1155ListingId);
            
            await marketplace.connect(seller2).updateListing(
                erc1155ListingId,
                0, // Keep same price
                additionalAmount
            );
            
            const updatedListing = await marketplace.getListing(erc1155ListingId);
            expect(updatedListing.amount).to.equal(listing.amount.add(additionalAmount));
        });
        
        it("Should cancel listing and return tokens", async function () {
            // Cancel ERC-721 listing
            await marketplace.connect(seller1).cancelListing(erc721ListingId);
            
            const listing721 = await marketplace.getListing(erc721ListingId);
            expect(listing721.status).to.equal(ListingStatus.CANCELLED);
            expect(await erc721Token.ownerOf(1)).to.equal(seller1.address);
            
            // Cancel ERC-1155 listing
            const listing1155Before = await marketplace.getListing(erc1155ListingId);
            const tokenId = listing1155Before.tokenId;
            const amount = listing1155Before.amount;
            
            await marketplace.connect(seller2).cancelListing(erc1155ListingId);
            
            const listing1155After = await marketplace.getListing(erc1155ListingId);
            expect(listing1155After.status).to.equal(ListingStatus.CANCELLED);
            expect(await erc1155Token.balanceOf(seller2.address, tokenId)).to.equal(100); // Original amount
        });
        
        it("Should expire listings after duration", async function () {
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]); // 8 days
            await ethers.provider.send("evm_mine");
            
            // Try to purchase expired listing
            await expect(
                marketplace.connect(buyer1).purchaseUnified({
                    listingId: erc721ListingId,
                    amount: 1,
                    commitment: ethers.constants.HashZero
                })
            ).to.be.revertedWith("ListingNotActive");
        });
    });
    
    describe("Privacy Support", function () {
        it("Should create listing with private payment token", async function () {
            const tokenId = 2;
            await erc721Token.mint(seller1.address, tokenId);
            await erc721Token.connect(seller1).approve(marketplace.address, tokenId);
            
            // Create private listing
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC721,
                erc721Token.address,
                tokenId,
                1,
                ethers.utils.parseUnits("100", 6),
                true, // Use privacy
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            const listing = await marketplace.getListing(listingId);
            expect(listing.usePrivacy).to.be.true;
            expect(listing.paymentToken).to.equal(privateOmniCoin.address);
        });
    });
    
    describe("Access Control", function () {
        it("Should restrict contract allowlist updates", async function () {
            await expect(
                marketplace.connect(buyer1).updateContractAllowlist(
                    ethers.constants.AddressZero,
                    true
                )
            ).to.be.reverted;
        });
        
        it("Should reject listings from non-allowed contracts", async function () {
            // Deploy new NFT contract
            const NewNFT = await ethers.getContractFactory("OmniNFT");
            const newNFT = await NewNFT.deploy("New NFT", "NEW", registry.address);
            await newNFT.deployed();
            
            await newNFT.mint(seller1.address, 1);
            await newNFT.connect(seller1).approve(marketplace.address, 1);
            
            // Should fail - contract not allowed
            await expect(
                marketplace.connect(seller1).createUnifiedListing(
                    TokenStandard.ERC721,
                    newNFT.address,
                    1,
                    1,
                    ethers.utils.parseUnits("100", 6),
                    false,
                    ListingType.FIXED_PRICE,
                    7 * 24 * 60 * 60
                )
            ).to.be.revertedWith("ContractNotAllowed");
        });
        
        it("Should allow operators to cancel any listing", async function () {
            const tokenId = 3;
            await erc721Token.mint(seller1.address, tokenId);
            await erc721Token.connect(seller1).approve(marketplace.address, tokenId);
            
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC721,
                erc721Token.address,
                tokenId,
                1,
                ethers.utils.parseUnits("100", 6),
                false,
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Grant operator role
            const OPERATOR_ROLE = await marketplace.OPERATOR_ROLE();
            await marketplace.grantRole(OPERATOR_ROLE, owner.address);
            
            // Operator can cancel
            await marketplace.connect(owner).cancelListing(listingId);
            
            const listing = await marketplace.getListing(listingId);
            expect(listing.status).to.equal(ListingStatus.CANCELLED);
        });
    });
    
    describe("Fee Management", function () {
        it("Should accumulate and withdraw fees", async function () {
            // Create and execute a sale
            const tokenId = 4;
            await erc721Token.mint(seller1.address, tokenId);
            await erc721Token.connect(seller1).approve(marketplace.address, tokenId);
            
            const price = ethers.utils.parseUnits("1000", 6);
            
            const tx = await marketplace.connect(seller1).createUnifiedListing(
                TokenStandard.ERC721,
                erc721Token.address,
                tokenId,
                1,
                price,
                false,
                ListingType.FIXED_PRICE,
                7 * 24 * 60 * 60
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "UnifiedListingCreated");
            const listingId = event.args.listingId;
            
            // Purchase
            await marketplace.connect(buyer1).purchaseUnified({
                listingId: listingId,
                amount: 1,
                commitment: ethers.constants.HashZero
            });
            
            // Check accumulated fees
            const expectedFee = price.mul(250).div(10000); // 2.5%
            expect(await marketplace.accumulatedFees(omniCoin.address)).to.equal(expectedFee);
            
            // Withdraw fees
            const treasuryBalanceBefore = await omniCoin.balanceOf(treasury.address);
            await marketplace.connect(owner).withdrawFees(omniCoin.address);
            
            expect(await marketplace.accumulatedFees(omniCoin.address)).to.equal(0);
            expect(await omniCoin.balanceOf(treasury.address)).to.equal(
                treasuryBalanceBefore.add(expectedFee)
            );
        });
    });
});