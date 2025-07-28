const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniERC1155", function () {
    let owner, creator, buyer1, buyer2, treasury, feeRecipient;
    let registry, omniCoin, privateOmniCoin, omniERC1155;
    
    // Token types
    const TokenType = {
        FUNGIBLE: 0,
        NON_FUNGIBLE: 1,
        SEMI_FUNGIBLE: 2,
        SERVICE: 3
    };
    
    beforeEach(async function () {
        [owner, creator, buyer1, buyer2, treasury, feeRecipient] = await ethers.getSigners();
        
        // Deploy Registry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy OmniCoin (public)
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // Deploy PrivateOmniCoin
        const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
        privateOmniCoin = await PrivateOmniCoin.deploy(await registry.getAddress());
        await privateOmniCoin.waitForDeployment();
        
        // Register payment tokens
        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress(),
            "OmniCoin"
        );
        
        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress(),
            "PrivateOmniCoin"
        );
        
        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress(),
            "Treasury"
        );
        
        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("FEE_RECIPIENT")),
            await feeRecipient.getAddress(),
            "FeeRecipient"
        );
        
        // Deploy OmniERC1155
        const OmniERC1155 = await ethers.getContractFactory("OmniERC1155");
        omniERC1155 = await OmniERC1155.deploy(await registry.getAddress(), "https://omnibazaar.com/metadata/");
        await omniERC1155.waitForDeployment();
        
        // Register OmniERC1155
        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNI_ERC1155")),
            await omniERC1155.getAddress(),
            "OmniERC1155"
        );
        
        // Fund users with tokens
        const fundAmount = ethers.parseUnits("10000", 6);
        await omniCoin.transfer(await creator.getAddress(), fundAmount);
        await omniCoin.transfer(await buyer1.getAddress(), fundAmount);
        await omniCoin.transfer(await buyer2.getAddress(), fundAmount);
        
        // Approve OmniERC1155 for spending
        await omniCoin.connect(creator).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(buyer1).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(buyer2).approve(await omniERC1155.getAddress(), ethers.MaxUint256);
    });
    
    describe("Token Creation", function () {
        it("Should create fungible tokens", async function () {
            const amount = 1000;
            const metadataURI = "fungible-token-metadata";
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
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            const tokenId = parsedEvent.args.tokenId;
            
            // Verify token info
            const tokenInfo = await omniERC1155.getTokenInfo(tokenId);
            expect(tokenInfo.creator).to.equal(await creator.getAddress());
            expect(tokenInfo.tokenType).to.equal(TokenType.FUNGIBLE);
            expect(tokenInfo.royaltyBps).to.equal(royaltyBps);
            expect(tokenInfo.metadataURI).to.equal(metadataURI);
            
            // Verify balance
            expect(await omniERC1155.balanceOf(await creator.getAddress(), tokenId)).to.equal(amount);
            expect(await omniERC1155.totalSupply(tokenId)).to.equal(amount);
        });
        
        it("Should create non-fungible tokens", async function () {
            const amount = 1; // NFTs should have amount of 1
            const metadataURI = "nft-metadata";
            const royaltyBps = 1000; // 10%
            
            const tx = await omniERC1155.connect(creator).createToken(
                amount,
                TokenType.NON_FUNGIBLE,
                metadataURI,
                royaltyBps
            );
            
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            const tokenId = parsedEvent.args.tokenId;
            
            // Verify token info
            const tokenInfo = await omniERC1155.getTokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.NON_FUNGIBLE);
            expect(await omniERC1155.balanceOf(await creator.getAddress(), tokenId)).to.equal(1);
        });
        
        it("Should create service tokens with validity period", async function () {
            const amount = 100;
            const validityPeriod = 30 * 24 * 60 * 60; // 30 days
            const metadataURI = "service-token-metadata";
            const pricePerUnit = ethers.parseUnits("50", 6); // 50 XOM
            
            const tx = await omniERC1155.connect(creator).createServiceToken(
                amount,
                validityPeriod,
                metadataURI,
                pricePerUnit
            );
            
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            const tokenId = parsedEvent.args.tokenId;
            
            // Verify token info
            const tokenInfo = await omniERC1155.getTokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.SERVICE);
            expect(tokenInfo.isForSale).to.be.true;
            expect(tokenInfo.pricePerUnit).to.equal(pricePerUnit);
            
            // Verify service info
            const serviceInfo = await omniERC1155.getServiceInfo(tokenId);
            expect(serviceInfo.validityPeriod).to.equal(validityPeriod);
            expect(serviceInfo.totalRedeemed).to.equal(0);
        });
        
        it("Should enforce royalty limits", async function () {
            const amount = 100;
            const metadataURI = "test-metadata";
            const invalidRoyalty = 10001; // Over 100%
            
            await expect(
                omniERC1155.connect(creator).createToken(
                    amount,
                    TokenType.FUNGIBLE,
                    metadataURI,
                    invalidRoyalty
                )
            ).to.be.revertedWith("Royalty too high");
        });
    });
    
    describe("Token Sales", function () {
        let tokenId;
        const tokenAmount = 100;
        const pricePerUnit = ethers.parseUnits("10", 6); // 10 XOM
        
        beforeEach(async function () {
            // Create token and list for sale
            const tx = await omniERC1155.connect(creator).createToken(
                tokenAmount,
                TokenType.FUNGIBLE,
                "sale-token",
                500 // 5% royalty
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            tokenId = parsedEvent.args.tokenId;
            
            // List for sale
            await omniERC1155.connect(creator).listForSale(
                tokenId,
                pricePerUnit,
                10, // max 10 per purchase
                false // use public token
            );
        });
        
        it("Should allow purchases with correct payment", async function () {
            const purchaseAmount = 5;
            const totalPrice = pricePerUnit* BigInt(purchaseAmount);
            
            const creatorBalanceBefore = await omniCoin.balanceOf(await creator.getAddress());
            const buyerBalanceBefore = await omniCoin.balanceOf(await buyer1.getAddress());
            
            await expect(
                omniERC1155.connect(buyer1).purchase(tokenId, purchaseAmount)
            ).to.emit(omniERC1155, "TokenPurchased")
            .withArgs(tokenId, await buyer1.getAddress(), purchaseAmount, totalPrice);
            
            // Verify token transfer
            expect(await omniERC1155.balanceOf(await buyer1.getAddress(), tokenId)).to.equal(purchaseAmount);
            expect(await omniERC1155.balanceOf(await creator.getAddress(), tokenId)).to.equal(tokenAmount - purchaseAmount);
            
            // Verify payment (minus fees)
            const marketplaceFee = totalPrice * BigInt(250) / BigInt(10000); // 2.5%
            const royalty = totalPrice * BigInt(500) / BigInt(10000); // 5%
            const sellerPayment = totalPrice - marketplaceFee - royalty;
            
            expect(await omniCoin.balanceOf(await creator.getAddress())).to.equal(
                creatorBalanceBefore + sellerPayment + royalty
            );
        });
        
        it("Should enforce purchase limits", async function () {
            const overLimitAmount = 11; // Max is 10
            
            await expect(
                omniERC1155.connect(buyer1).purchase(tokenId, overLimitAmount)
            ).to.be.revertedWith("Exceeds max per purchase");
        });
        
        it("Should update sale listing", async function () {
            const newPrice = ethers.parseUnits("15", 6);
            const newMaxPerPurchase = 20;
            
            await omniERC1155.connect(creator).updateListing(
                tokenId,
                newPrice,
                newMaxPerPurchase,
                false
            );
            
            const tokenInfo = await omniERC1155.getTokenInfo(tokenId);
            expect(tokenInfo.pricePerUnit).to.equal(newPrice);
            expect(tokenInfo.maxPerPurchase).to.equal(newMaxPerPurchase);
        });
        
        it("Should cancel sale listing", async function () {
            await omniERC1155.connect(creator).cancelListing(tokenId);
            
            const tokenInfo = await omniERC1155.getTokenInfo(tokenId);
            expect(tokenInfo.isForSale).to.be.false;
            
            // Should not be able to purchase
            await expect(
                omniERC1155.connect(buyer1).purchase(tokenId, 1)
            ).to.be.revertedWith("Not for sale");
        });
    });
    
    describe("Service Token Redemption", function () {
        let serviceTokenId;
        const validityPeriod = 7 * 24 * 60 * 60; // 7 days
        
        beforeEach(async function () {
            // Create service token
            const tx = await omniERC1155.connect(creator).createServiceToken(
                50,
                validityPeriod,
                "consultation-service",
                ethers.parseUnits("100", 6)
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            serviceTokenId = parsedEvent.args.tokenId;
            
            // Buy some service tokens
            await omniERC1155.connect(buyer1).purchase(serviceTokenId, 5);
        });
        
        it("Should allow service redemption within validity period", async function () {
            await expect(
                omniERC1155.connect(buyer1).redeemService(serviceTokenId, 1, "Order #123")
            ).to.emit(omniERC1155, "ServiceRedeemed")
            .withArgs(serviceTokenId, await buyer1.getAddress(), 1);
            
            // Verify balance decreased
            expect(await omniERC1155.balanceOf(await buyer1.getAddress(), serviceTokenId)).to.equal(4);
            
            // Verify redemption recorded
            const serviceInfo = await omniERC1155.getServiceInfo(serviceTokenId);
            expect(serviceInfo.totalRedeemed).to.equal(1);
        });
        
        it("Should track individual redemptions", async function () {
            await omniERC1155.connect(buyer1).redeemService(serviceTokenId, 1, "Order #1");
            await omniERC1155.connect(buyer1).redeemService(serviceTokenId, 2, "Order #2");
            
            const redemptions = await omniERC1155.getUserRedemptions(await buyer1.getAddress(), serviceTokenId);
            expect(redemptions.length).to.equal(2);
            expect(redemptions[0].amount).to.equal(1);
            expect(redemptions[0].metadata).to.equal("Order #1");
            expect(redemptions[1].amount).to.equal(2);
            expect(redemptions[1].metadata).to.equal("Order #2");
        });
        
        it("Should prevent redemption after expiry", async function () {
            // Fast forward past validity period
            await ethers.provider.send("evm_increaseTime", [validityPeriod + 1]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                omniERC1155.connect(buyer1).redeemService(serviceTokenId, 1, "Late order")
            ).to.be.revertedWith("Service token expired");
        });
    });
    
    describe("Batch Operations", function () {
        let tokenIds = [];
        
        beforeEach(async function () {
            // Create multiple tokens
            for (let i = 0; i < 3; i++) {
                const tx = await omniERC1155.connect(creator).createToken(
                    100,
                    TokenType.FUNGIBLE,
                    `token-${i}`,
                    250
                );
                const receipt = await tx.wait();
                const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
                tokenIds.push(parsedEvent.args.tokenId);
            }
        });
        
        it("Should support batch transfers", async function () {
            const amounts = [10, 20, 30];
            
            await omniERC1155.connect(creator).safeBatchTransferFrom(
                await creator.getAddress(),
                await buyer1.getAddress(),
                tokenIds,
                amounts,
                "0x"
            );
            
            // Verify all balances
            for (let i = 0; i < tokenIds.length; i++) {
                expect(await omniERC1155.balanceOf(await buyer1.getAddress(), tokenIds[i])).to.equal(amounts[i]);
            }
        });
        
        it("Should support batch balance queries", async function () {
            const accounts = [await creator.getAddress(), await creator.getAddress(), await creator.getAddress()];
            const balances = await omniERC1155.balanceOfBatch(accounts, tokenIds);
            
            for (let i = 0; i < balances.length; i++) {
                expect(balances[i]).to.equal(100);
            }
        });
    });
    
    describe("Access Control", function () {
        it("Should restrict minting to authorized roles", async function () {
            const tx = await omniERC1155.connect(creator).createToken(
                100,
                TokenType.FUNGIBLE,
                "test",
                0
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            const tokenId = parsedEvent.args.tokenId;
            
            // Non-owner should not be able to mint
            await expect(
                omniERC1155.connect(buyer1).mint(tokenId, 50, await buyer1.getAddress())
            ).to.be.revertedWith("Not authorized");
        });
        
        it("Should allow admin to pause/unpause", async function () {
            // Pause contract
            await omniERC1155.connect(owner).pause();
            
            // Should not be able to create tokens while paused
            await expect(
                omniERC1155.connect(creator).createToken(
                    100,
                    TokenType.FUNGIBLE,
                    "paused-test",
                    0
                )
            ).to.be.revertedWith("Pausable: paused");
            
            // Unpause
            await omniERC1155.connect(owner).unpause();
            
            // Should work again
            await expect(
                omniERC1155.connect(creator).createToken(
                    100,
                    TokenType.FUNGIBLE,
                    "unpaused-test",
                    0
                )
            ).to.not.be.reverted;
        });
    });
    
    describe("URI Management", function () {
        it("Should return correct token URI", async function () {
            const metadataURI = "custom-metadata";
            const tx = await omniERC1155.connect(creator).createToken(
                1,
                TokenType.NON_FUNGIBLE,
                metadataURI,
                0
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            const tokenId = parsedEvent.args.tokenId;
            
            const uri = await omniERC1155.uri(tokenId);
            expect(uri).to.equal(`https://omnibazaar.com/metadata/${metadataURI}`);
        });
        
        it("Should allow admin to update base URI", async function () {
            const newBaseURI = "https://new-domain.com/metadata/";
            await omniERC1155.connect(owner).setURI(newBaseURI);
            
            const tx = await omniERC1155.connect(creator).createToken(
                1,
                TokenType.NON_FUNGIBLE,
                "test",
                0
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = omniERC1155.interface.parseLog(log);
                    return parsed.name === "TokenCreated";
                } catch { return false; }
            });
            const parsedEvent = omniERC1155.interface.parseLog(event);
            const tokenId = parsedEvent.args.tokenId;
            
            const uri = await omniERC1155.uri(tokenId);
            expect(uri).to.equal(`${newBaseURI}test`);
        });
    });
});