const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniERC1155 Minimal Test", function () {
    let owner, creator, buyer1, treasury;
    let registry, omniCoin;
    let omniERC1155;
    
    // Token types
    const TokenType = {
        FUNGIBLE: 0,
        NON_FUNGIBLE: 1,
        SEMI_FUNGIBLE: 2,
        SERVICE: 3
    };
    
    beforeEach(async function () {
        [owner, creator, buyer1, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        
        // Deploy OmniERC1155 with actual registry
        const OmniERC1155 = await ethers.getContractFactory("OmniERC1155");
        omniERC1155 = await OmniERC1155.deploy(await registry.getAddress(), "https://omnibazaar.com/metadata/");
        await omniERC1155.waitForDeployment();
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
                } catch (e) {
                    return false;
                }
            });
            
            expect(event).to.not.be.undefined;
            
            // Check token was created with correct properties
            const tokenId = 1;
            const tokenInfo = await omniERC1155.tokenInfo(tokenId);
            expect(tokenInfo.tokenType).to.equal(TokenType.FUNGIBLE);
            expect(tokenInfo.creator).to.equal(await creator.getAddress());
            expect(tokenInfo.totalSupply).to.equal(amount);
            expect(tokenInfo.maxSupply).to.equal(amount);
            expect(tokenInfo.royaltyBps).to.equal(royaltyBps);
            
            // Check creator balance
            const balance = await omniERC1155.balanceOf(await creator.getAddress(), tokenId);
            expect(balance).to.equal(amount);
        });
        
        it("Should create non-fungible tokens", async function () {
            const metadataURI = "nft-metadata";
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
        });
    });
});