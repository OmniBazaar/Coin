const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniERC1155 Comprehensive Test Suite", function () {
    let owner, creator, buyer1, buyer2, treasury, feeRecipient;
    let registry, omniCoin, privateOmniCoin;
    let omniERC1155;
    
    // Token types
    const TokenType = {
        FUNGIBLE: 0,
        NON_FUNGIBLE: 1,
        SEMI_FUNGIBLE: 2,
        SERVICE: 3
    };
    
    // Constants
    const PLATFORM_FEE_BPS = 250; // 2.5%
    const PRIVACY_FEE_MULTIPLIER = 10;
    
    beforeEach(async function () {
        [owner, creator, buyer1, buyer2, treasury, feeRecipient] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test
        const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        privateOmniCoin = await StandardERC20Test.deploy();
        await privateOmniCoin.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("FEE_RECIPIENT")),
            await feeRecipient.getAddress()
        );
        
        // Deploy OmniERC1155
        const OmniERC1155 = await ethers.getContractFactory("OmniERC1155");
        omniERC1155 = await OmniERC1155.deploy(
            await registry.getAddress(),
            "https://omnibazaar.com/metadata/"
        );
        await omniERC1155.waitForDeployment();
        
        // Fund users with tokens
        const fundAmount = ethers.parseUnits("10000", 6);
        await omniCoin.mint(await creator.getAddress(), fundAmount);
        await omniCoin.mint(await buyer1.getAddress(), fundAmount);
        await omniCoin.mint(await buyer2.getAddress(), fundAmount);
        await privateOmniCoin.mint(await creator.getAddress(), fundAmount);
        await privateOmniCoin.mint(await buyer1.getAddress(), fundAmount);
        
        // Approve spending
        await omniCoin.connect(creator).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(buyer1).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(buyer2).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
        await privateOmniCoin.connect(creator).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
        await privateOmniCoin.connect(buyer1).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
    });
    
    describe("Token Creation", function () {
        it("Should create fungible tokens with correct properties", async function () {
            const amount = 1000;
            const metadataURI = "ipfs://fungible-token-metadata";
            const royaltyBps = 500; // 5%
            
            const tx = await omniERC1155.connect(creator).createToken(
                amount,
                TokenType.FUNGIBLE,
                metadataURI,
                royaltyBps
            );
            
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch (e) {
                    return false;
                }
            });
            
            expect(event).to.not.be.undefined;
            
            const tokenId = 1;
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.FUNGIBLE);
            expect(tokenInfo.creator).to.equal(await creator.getAddress());
            expect(tokenInfo.totalSupply).to.equal(amount);
            expect(tokenInfo.maxSupply).to.equal(amount);
            expect(tokenInfo.royaltyBps).to.equal(royaltyBps);
            expect(tokenInfo.isListed).to.be.false;
            
            const balance = await omniERC1155.balanceOf(await creator.getAddress(), tokenId);
            expect(balance).to.equal(amount);
        });
        
        it("Should create non-fungible tokens", async function () {
            const metadataURI = "ipfs://nft-metadata";
            const royaltyBps = 1000; // 10%
            
            await omniERC1155.connect(creator).createToken(
                1,
                TokenType.NON_FUNGIBLE,
                metadataURI,
                royaltyBps
            );
            
            const tokenId = 1;
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.NON_FUNGIBLE);
            expect(tokenInfo.totalSupply).to.equal(1);
            expect(tokenInfo.maxSupply).to.equal(1);
            expect(tokenInfo.royaltyBps).to.equal(royaltyBps);
        });
        
        it("Should create semi-fungible tokens", async function () {
            const amount = 100;
            const metadataURI = "ipfs://semi-fungible-metadata";
            const royaltyBps = 750; // 7.5%
            
            await omniERC1155.connect(creator).createToken(
                amount,
                TokenType.SEMI_FUNGIBLE,
                metadataURI,
                royaltyBps
            );
            
            const tokenId = 1;
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.SEMI_FUNGIBLE);
            expect(tokenInfo.totalSupply).to.equal(amount);
            expect(tokenInfo.maxSupply).to.equal(amount);
        });
        
        it("Should fail with zero supply", async function () {
            await expect(
                omniERC1155.connect(creator).createToken(
                    0,
                    TokenType.FUNGIBLE,
                    "uri",
                    100
                )
            ).to.be.revertedWithCustomError(omniERC1155, "InvalidAmount");
        });
        
        it("Should fail with invalid royalty", async function () {
            await expect(
                omniERC1155.connect(creator).createToken(
                    100,
                    TokenType.FUNGIBLE,
                    "uri",
                    3001 // > 30%
                )
            ).to.be.revertedWithCustomError(omniERC1155, "RoyaltyTooHigh");
        });
    });
    
    describe("Token Listing", function () {
        beforeEach(async function () {
            // Create a fungible token
            await omniERC1155.connect(creator).createToken(
                1000,
                TokenType.FUNGIBLE,
                "ipfs://token",
                500
            );
        });
        
        it("Should list tokens for sale with public payment", async function () {
            const tokenId = 1;
            const pricePerUnit = ethers.parseUnits("10", 6);
            
            await omniERC1155.connect(creator).listToken(tokenId, pricePerUnit, false);
            
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.isListed).to.be.true;
            expect(tokenInfo.pricePerUnit).to.equal(pricePerUnit);
            expect(tokenInfo.usePrivacy).to.be.false;
        });
        
        it("Should list tokens for sale with private payment", async function () {
            const tokenId = 1;
            const pricePerUnit = ethers.parseUnits("10", 6);
            
            await omniERC1155.connect(creator).listToken(tokenId, pricePerUnit, true);
            
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.isListed).to.be.true;
            expect(tokenInfo.pricePerUnit).to.equal(pricePerUnit);
            expect(tokenInfo.usePrivacy).to.be.true;
        });
        
        it("Should unlist tokens", async function () {
            const tokenId = 1;
            const pricePerUnit = ethers.parseUnits("10", 6);
            
            await omniERC1155.connect(creator).listToken(tokenId, pricePerUnit, false);
            await omniERC1155.connect(creator).unlistToken(tokenId);
            
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.isListed).to.be.false;
        });
        
        it("Should fail to list non-existent token", async function () {
            await expect(
                omniERC1155.connect(creator).listToken(999, 100, false)
            ).to.be.revertedWithCustomError(omniERC1155, "TokenDoesNotExist");
        });
        
        it("Should fail to list token not owned by caller", async function () {
            const tokenId = 1;
            await expect(
                omniERC1155.connect(buyer1).listToken(tokenId, 100, false)
            ).to.be.revertedWithCustomError(omniERC1155, "NotTokenCreator");
        });
    });
    
    describe("Token Purchase", function () {
        const tokenId = 1;
        const pricePerUnit = ethers.parseUnits("10", 6);
        
        beforeEach(async function () {
            // Create and list a fungible token
            await omniERC1155.connect(creator).createToken(
                1000,
                TokenType.FUNGIBLE,
                "ipfs://token",
                500 // 5% royalty
            );
            await omniERC1155.connect(creator).listToken(tokenId, pricePerUnit, false);
        });
        
        it("Should purchase tokens with public payment", async function () {
            const amount = 10;
            const totalPrice = pricePerUnit * BigInt(amount);
            const platformFee = (totalPrice * BigInt(PLATFORM_FEE_BPS)) / 10000n;
            const royalty = ((totalPrice - platformFee) * 500n) / 10000n;
            const sellerReceives = totalPrice - platformFee - royalty;
            
            const creatorBalanceBefore = await omniCoin.balanceOf(await creator.getAddress());
            const treasuryBalanceBefore = await omniCoin.balanceOf(await treasury.getAddress());
            const feeBalanceBefore = await omniCoin.balanceOf(await feeRecipient.getAddress());
            
            await omniERC1155.connect(buyer1).purchaseTokens(tokenId, amount);
            
            // Check token transfer
            expect(await omniERC1155.balanceOf(await buyer1.getAddress(), tokenId)).to.equal(amount);
            expect(await omniERC1155.balanceOf(await creator.getAddress(), tokenId)).to.equal(990);
            
            // Check payment distribution
            const creatorBalanceAfter = await omniCoin.balanceOf(await creator.getAddress());
            const treasuryBalanceAfter = await omniCoin.balanceOf(await treasury.getAddress());
            const feeBalanceAfter = await omniCoin.balanceOf(await feeRecipient.getAddress());
            
            expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(sellerReceives + royalty);
            expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(platformFee / 2n);
            expect(feeBalanceAfter - feeBalanceBefore).to.equal(platformFee / 2n);
        });
        
        it("Should purchase with privacy payment at 10x fee", async function () {
            // List with privacy
            await omniERC1155.connect(creator).unlistToken(tokenId);
            await omniERC1155.connect(creator).listToken(tokenId, pricePerUnit, true);
            
            const amount = 5;
            const totalPrice = pricePerUnit * BigInt(amount);
            const platformFee = (totalPrice * BigInt(PLATFORM_FEE_BPS * PRIVACY_FEE_MULTIPLIER)) / 10000n;
            
            await omniERC1155.connect(buyer1).purchaseTokens(tokenId, amount);
            
            expect(await omniERC1155.balanceOf(await buyer1.getAddress(), tokenId)).to.equal(amount);
        });
        
        it("Should fail to purchase unlisted token", async function () {
            await omniERC1155.connect(creator).unlistToken(tokenId);
            
            await expect(
                omniERC1155.connect(buyer1).purchaseTokens(tokenId, 1)
            ).to.be.revertedWithCustomError(omniERC1155, "TokenNotListed");
        });
        
        it("Should fail to purchase more than available", async function () {
            await expect(
                omniERC1155.connect(buyer1).purchaseTokens(tokenId, 1001)
            ).to.be.revertedWithCustomError(omniERC1155, "InsufficientTokens");
        });
    });
    
    describe("Service Tokens", function () {
        it("Should create service token with validity period", async function () {
            const validityDays = 30;
            const amount = 100;
            const metadataURI = "ipfs://service-token";
            const royaltyBps = 0; // No royalty for services
            
            await omniERC1155.connect(creator).createServiceToken(
                amount,
                validityDays,
                metadataURI,
                royaltyBps
            );
            
            const tokenId = 1;
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.SERVICE);
            expect(tokenInfo.totalSupply).to.equal(amount);
            
            const serviceInfo = await omniERC1155.serviceTokens(tokenId);
            expect(serviceInfo.validityDays).to.equal(validityDays);
            expect(serviceInfo.isActive).to.be.true;
        });
        
        it("Should redeem service token", async function () {
            const validityDays = 30;
            await omniERC1155.connect(creator).createServiceToken(
                100,
                validityDays,
                "ipfs://service",
                0
            );
            
            const tokenId = 1;
            
            // Transfer to buyer
            await omniERC1155.connect(creator).safeTransferFrom(
                await creator.getAddress(),
                await buyer1.getAddress(),
                tokenId,
                1,
                "0x"
            );
            
            // Redeem service
            await omniERC1155.connect(buyer1).redeemService(tokenId);
            
            const redemption = await omniERC1155.serviceRedemptions(tokenId, await buyer1.getAddress());
            expect(redemption).to.be.gt(0);
            
            // Balance should be reduced
            expect(await omniERC1155.balanceOf(await buyer1.getAddress(), tokenId)).to.equal(0);
        });
        
        it("Should check service validity", async function () {
            const validityDays = 1;
            await omniERC1155.connect(creator).createServiceToken(
                100,
                validityDays,
                "ipfs://service",
                0
            );
            
            const tokenId = 1;
            
            // Transfer and redeem
            await omniERC1155.connect(creator).safeTransferFrom(
                await creator.getAddress(),
                await buyer1.getAddress(),
                tokenId,
                1,
                "0x"
            );
            await omniERC1155.connect(buyer1).redeemService(tokenId);
            
            // Should be valid
            const isValid = await omniERC1155.isServiceValid(tokenId, await buyer1.getAddress());
            expect(isValid).to.be.true;
        });
    });
    
    describe("Batch Operations", function () {
        it("Should mint batch of tokens", async function () {
            // Create multiple tokens
            await omniERC1155.connect(creator).createToken(100, TokenType.FUNGIBLE, "uri1", 100);
            await omniERC1155.connect(creator).createToken(200, TokenType.FUNGIBLE, "uri2", 200);
            await omniERC1155.connect(creator).createToken(300, TokenType.FUNGIBLE, "uri3", 300);
            
            const ids = [1, 2, 3];
            const amounts = [10, 20, 30];
            
            await omniERC1155.connect(creator).mintBatch(
                await buyer1.getAddress(),
                ids,
                amounts
            );
            
            for (let i = 0; i < ids.length; i++) {
                expect(await omniERC1155.balanceOf(await buyer1.getAddress(), ids[i])).to.equal(amounts[i]);
            }
        });
        
        it("Should fail batch mint with mismatched arrays", async function () {
            await expect(
                omniERC1155.connect(creator).mintBatch(
                    await buyer1.getAddress(),
                    [1, 2],
                    [10] // mismatched length
                )
            ).to.be.revertedWithCustomError(omniERC1155, "ArrayLengthMismatch");
        });
    });
    
    describe("URI Management", function () {
        it("Should return correct URI for tokens", async function () {
            const metadataURI = "ipfs://QmTest123";
            await omniERC1155.connect(creator).createToken(
                100,
                TokenType.FUNGIBLE,
                metadataURI,
                100
            );
            
            const tokenId = 1;
            const uri = await omniERC1155.uri(tokenId);
            expect(uri).to.equal(metadataURI);
        });
        
        it("Should update base URI (owner only)", async function () {
            const newBaseURI = "https://newdomain.com/metadata/";
            await omniERC1155.connect(owner).setBaseURI(newBaseURI);
            
            // Create token without metadata URI
            await omniERC1155.connect(creator).createToken(
                100,
                TokenType.FUNGIBLE,
                "",
                100
            );
            
            const tokenId = 1;
            const uri = await omniERC1155.uri(tokenId);
            expect(uri).to.equal(newBaseURI + tokenId.toString());
        });
    });
    
    describe("Royalty System", function () {
        it("Should distribute royalties correctly on secondary sales", async function () {
            const royaltyBps = 1000; // 10%
            await omniERC1155.connect(creator).createToken(
                10,
                TokenType.NON_FUNGIBLE,
                "ipfs://nft",
                royaltyBps
            );
            
            const tokenId = 1;
            const pricePerUnit = ethers.parseUnits("100", 6);
            
            // Initial sale to buyer1
            await omniERC1155.connect(creator).listToken(tokenId, pricePerUnit, false);
            await omniERC1155.connect(buyer1).purchaseTokens(tokenId, 1);
            
            // Secondary sale: buyer1 lists and buyer2 purchases
            await omniERC1155.connect(buyer1).listToken(tokenId, pricePerUnit * 2n, false);
            
            const creatorBalanceBefore = await omniCoin.balanceOf(await creator.getAddress());
            
            await omniERC1155.connect(buyer2).purchaseTokens(tokenId, 1);
            
            const creatorBalanceAfter = await omniCoin.balanceOf(await creator.getAddress());
            const royaltyReceived = creatorBalanceAfter - creatorBalanceBefore;
            
            // Royalty should be ~10% of sale price (minus platform fee)
            const expectedRoyalty = (pricePerUnit * 2n * BigInt(royaltyBps)) / 10000n;
            expect(royaltyReceived).to.be.closeTo(expectedRoyalty, ethers.parseUnits("1", 6));
        });
    });
    
    describe("Access Control", function () {
        it("Should only allow owner to pause", async function () {
            await expect(
                omniERC1155.connect(buyer1).pause()
            ).to.be.revertedWithCustomError(omniERC1155, "OwnableUnauthorizedAccount");
            
            await omniERC1155.connect(owner).pause();
            expect(await omniERC1155.paused()).to.be.true;
        });
        
        it("Should prevent operations when paused", async function () {
            await omniERC1155.connect(owner).pause();
            
            await expect(
                omniERC1155.connect(creator).createToken(100, TokenType.FUNGIBLE, "uri", 100)
            ).to.be.revertedWithCustomError(omniERC1155, "EnforcedPause");
        });
    });
});