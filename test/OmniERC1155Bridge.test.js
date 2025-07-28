const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniERC1155Bridge", function () {
    let owner, importer1, importer2, validator, treasury;
    let registry, omniCoin, omniERC1155, bridge;
    let externalERC1155;
    
    beforeEach(async function () {
        [owner, importer1, importer2, validator, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(await owner.getAddress());
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
        
        // Deploy OmniERC1155
        const OmniERC1155 = await ethers.getContractFactory("OmniERC1155");
        omniERC1155 = await OmniERC1155.deploy(await registry.getAddress(), "https://omnibazaar.com/");
        await omniERC1155.waitForDeployment();
        
        // Deploy Bridge
        const Bridge = await ethers.getContractFactory("OmniERC1155Bridge");
        bridge = await Bridge.deploy(await registry.getAddress(), await omniERC1155.getAddress());
        await bridge.waitForDeployment();
        
        // Grant bridge minting role on OmniERC1155
        const MINTER_ROLE = await omniERC1155.MINTER_ROLE();
        await omniERC1155.grantRole(MINTER_ROLE, await bridge.getAddress());
        
        // Deploy another OmniERC1155 instance to act as external ERC1155
        const ExternalERC1155 = await ethers.getContractFactory("OmniERC1155");
        externalERC1155 = await ExternalERC1155.deploy(await registry.getAddress(), "https://external.com/");
        await externalERC1155.waitForDeployment();
        
        // Fund importers
        const fundAmount = ethers.parseUnits("1000", 6);
        await omniCoin.mint(await importer1.getAddress(), fundAmount);
        await omniCoin.mint(await importer2.getAddress(), fundAmount);
        
        // Mint external tokens
        await externalERC1155.mint(await importer1.getAddress(), 1, 100, "0x");
        await externalERC1155.mint(await importer1.getAddress(), 2, 50, "0x");
        await externalERC1155.mint(await importer2.getAddress(), 3, 200, "0x");
        
        // Approve bridge
        await externalERC1155.connect(importer1).setApprovalForAll(await bridge.getAddress(), true);
        await externalERC1155.connect(importer2).setApprovalForAll(await bridge.getAddress(), true);
    });
    
    describe("Chain Management", function () {
        it("Should have default chains configured", async function () {
            expect(await bridge.supportedChains("ethereum")).to.be.true;
            expect(await bridge.supportedChains("polygon")).to.be.true;
            expect(await bridge.supportedChains("bsc")).to.be.true;
            expect(await bridge.supportedChains("avalanche")).to.be.true;
            expect(await bridge.supportedChains("arbitrum")).to.be.true;
        });
        
        it("Should have correct import fees", async function () {
            expect(await bridge.importFees("ethereum")).to.equal(ethers.parseUnits("10", 6));
            expect(await bridge.importFees("polygon")).to.equal(ethers.parseUnits("1", 6));
            expect(await bridge.importFees("bsc")).to.equal(ethers.parseUnits("5", 6));
        });
        
        it("Should allow adding new chains", async function () {
            const BRIDGE_OPERATOR_ROLE = await bridge.BRIDGE_OPERATOR_ROLE();
            await bridge.grantRole(BRIDGE_OPERATOR_ROLE, await owner.getAddress());
            
            await expect(
                bridge.connect(owner).addChain("optimism", await validator.getAddress(), ethers.parseUnits("2", 6))
            ).to.emit(bridge, "ChainAdded")
            .withArgs("optimism", await validator.getAddress(), ethers.parseUnits("2", 6));
            
            expect(await bridge.supportedChains("optimism")).to.be.true;
            expect(await bridge.chainValidators("optimism")).to.equal(await validator.getAddress());
        });
    });
    
    describe("Cross-Chain Import", function () {
        it("Should import tokens from external chain", async function () {
            const originalContract = "0x1234567890123456789012345678901234567890";
            const tokenId = 100;
            const amount = 50;
            const sourceChain = "ethereum";
            const metadataUri = "imported-token-metadata";
            const fee = await bridge.importFees(sourceChain);
            
            const tx = await bridge.connect(importer1).importFromChain(
                originalContract,
                tokenId,
                amount,
                sourceChain,
                metadataUri,
                { value: fee }
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenImported");
            const localTokenId = event.args.localTokenId;
            
            // Verify import
            expect(event.args.originalContract).to.equal(originalContract);
            expect(event.args.originalTokenId).to.equal(tokenId);
            expect(event.args.importer).to.equal(importer1.address);
            expect(event.args.amount).to.equal(amount);
            expect(event.args.sourceChain).to.equal(sourceChain);
            
            // Verify local token created
            expect(await omniERC1155.balanceOf(importer1.address, localTokenId)).to.equal(amount);
            
            // Verify import record
            const importHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ["address", "uint256", "string"],
                    [originalContract, tokenId, sourceChain]
                )
            );
            const importedToken = await bridge.importedTokens(importHash);
            expect(importedToken.localTokenId).to.equal(localTokenId);
            expect(importedToken.totalImported).to.equal(amount);
        });
        
        it("Should reuse existing local token for same import", async function () {
            const originalContract = "0x1234567890123456789012345678901234567890";
            const tokenId = 100;
            const sourceChain = "ethereum";
            const fee = await bridge.importFees(sourceChain);
            
            // First import
            let tx = await bridge.connect(importer1).importFromChain(
                originalContract,
                tokenId,
                30,
                sourceChain,
                "metadata1",
                { value: fee }
            );
            let receipt = await tx.wait();
            let event = receipt.events.find(e => e.event === "TokenImported");
            const localTokenId = event.args.localTokenId;
            
            // Second import - same token
            tx = await bridge.connect(importer2).importFromChain(
                originalContract,
                tokenId,
                20,
                sourceChain,
                "metadata2", // Different metadata ignored
                { value: fee }
            );
            receipt = await tx.wait();
            event = receipt.events.find(e => e.event === "TokenImported");
            
            // Should reuse same local token ID
            expect(event.args.localTokenId).to.equal(localTokenId);
            
            // Verify balances
            expect(await omniERC1155.balanceOf(importer1.address, localTokenId)).to.equal(30);
            expect(await omniERC1155.balanceOf(importer2.address, localTokenId)).to.equal(20);
            
            // Verify total imported
            const importHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ["address", "uint256", "string"],
                    [originalContract, tokenId, sourceChain]
                )
            );
            const importedToken = await bridge.importedTokens(importHash);
            expect(importedToken.totalImported).to.equal(50);
        });
        
        it("Should refund excess fees", async function () {
            const fee = await bridge.importFees("polygon");
            const excessFee = fee.mul(2); // Send double the required fee
            
            const balanceBefore = await ethers.provider.getBalance(importer1.address);
            
            const tx = await bridge.connect(importer1).importFromChain(
                "0x1234567890123456789012345678901234567890",
                1,
                10,
                "polygon",
                "test",
                { value: excessFee }
            );
            
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(tx.gasPrice);
            
            const balanceAfter = await ethers.provider.getBalance(importer1.address);
            const actualCost = balanceBefore.sub(balanceAfter).sub(gasUsed);
            
            // Should only pay the required fee
            expect(actualCost).to.be.closeTo(fee, ethers.utils.parseUnits("0.01", 6));
        });
        
        it("Should reject unsupported chains", async function () {
            await expect(
                bridge.connect(importer1).importFromChain(
                    "0x1234567890123456789012345678901234567890",
                    1,
                    10,
                    "unsupported-chain",
                    "test",
                    { value: ethers.utils.parseUnits("10", 6) }
                )
            ).to.be.revertedWith("UnsupportedChain");
        });
        
        it("Should reject insufficient fee", async function () {
            const fee = await bridge.importFees("ethereum");
            
            await expect(
                bridge.connect(importer1).importFromChain(
                    "0x1234567890123456789012345678901234567890",
                    1,
                    10,
                    "ethereum",
                    "test",
                    { value: fee.sub(1) } // 1 wei less than required
                )
            ).to.be.revertedWith("InsufficientFee");
        });
    });
    
    describe("Same-Chain Wrapping", function () {
        it("Should wrap same-chain ERC1155 tokens", async function () {
            const tokenId = 1;
            const amount = 50;
            const balanceBefore = await externalERC1155.balanceOf(importer1.address, tokenId);
            
            const tx = await bridge.connect(importer1).wrapToken(
                externalERC1155.address,
                tokenId,
                amount
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenImported");
            const localTokenId = event.args.localTokenId;
            
            // Verify external tokens transferred to bridge
            expect(await externalERC1155.balanceOf(bridge.address, tokenId)).to.equal(amount);
            expect(await externalERC1155.balanceOf(importer1.address, tokenId)).to.equal(
                balanceBefore.sub(amount)
            );
            
            // Verify wrapped tokens minted
            expect(await omniERC1155.balanceOf(importer1.address, localTokenId)).to.equal(amount);
            
            // Verify import marked as wrapped
            const importHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ["address", "uint256", "string"],
                    [externalERC1155.address, tokenId, "omnichain"]
                )
            );
            const importedToken = await bridge.importedTokens(importHash);
            expect(importedToken.isWrapped).to.be.true;
            expect(importedToken.originalChain).to.equal("omnichain");
        });
        
        it("Should fetch metadata when wrapping", async function () {
            // Set metadata on external token
            await externalERC1155.setURI(2, "https://external.com/token/2");
            
            const tx = await bridge.connect(importer1).wrapToken(
                externalERC1155.address,
                2,
                25
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenImported");
            const localTokenId = event.args.localTokenId;
            
            // Verify metadata cached
            const importHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ["address", "uint256", "string"],
                    [externalERC1155.address, 2, "omnichain"]
                )
            );
            const metadata = await bridge.metadataCache(importHash);
            expect(metadata.uri).to.equal("https://external.com/token/2");
            expect(metadata.cached).to.be.true;
        });
    });
    
    describe("Token Export", function () {
        let localTokenId;
        let importHash;
        
        beforeEach(async function () {
            // Import some tokens first
            const originalContract = "0x1234567890123456789012345678901234567890";
            const tokenId = 100;
            const amount = 100;
            const sourceChain = "ethereum";
            const fee = await bridge.importFees(sourceChain);
            
            const tx = await bridge.connect(importer1).importFromChain(
                originalContract,
                tokenId,
                amount,
                sourceChain,
                "test-metadata",
                { value: fee }
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenImported");
            localTokenId = event.args.localTokenId;
            
            importHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ["address", "uint256", "string"],
                    [originalContract, tokenId, sourceChain]
                )
            );
        });
        
        it("Should export tokens back to original chain", async function () {
            const exportAmount = 40;
            const recipient = "0x9876543210987654321098765432109876543210";
            
            // Approve bridge to burn tokens
            await omniERC1155.connect(importer1).setApprovalForAll(bridge.address, true);
            
            const balanceBefore = await omniERC1155.balanceOf(importer1.address, localTokenId);
            
            await expect(
                bridge.connect(importer1).exportToChain(
                    localTokenId,
                    exportAmount,
                    "ethereum",
                    recipient
                )
            ).to.emit(bridge, "TokenExported")
            .withArgs(localTokenId, recipient, exportAmount, "ethereum");
            
            // Verify tokens burned
            expect(await omniERC1155.balanceOf(importer1.address, localTokenId)).to.equal(
                balanceBefore.sub(exportAmount)
            );
            
            // Verify import record updated
            const importedToken = await bridge.importedTokens(importHash);
            expect(importedToken.totalImported).to.equal(60); // 100 - 40
        });
        
        it("Should unwrap same-chain tokens", async function () {
            // Wrap some tokens first
            const tokenId = 3;
            const wrapAmount = 100;
            
            let tx = await bridge.connect(importer2).wrapToken(
                externalERC1155.address,
                tokenId,
                wrapAmount
            );
            
            let receipt = await tx.wait();
            let event = receipt.events.find(e => e.event === "TokenImported");
            const wrappedTokenId = event.args.localTokenId;
            
            // Approve and unwrap
            await omniERC1155.connect(importer2).setApprovalForAll(bridge.address, true);
            
            const externalBalanceBefore = await externalERC1155.balanceOf(importer2.address, tokenId);
            
            await bridge.connect(importer2).exportToChain(
                wrappedTokenId,
                50,
                "omnichain",
                importer2.address
            );
            
            // Verify external tokens returned
            expect(await externalERC1155.balanceOf(importer2.address, tokenId)).to.equal(
                externalBalanceBefore.add(50)
            );
            
            // Verify wrapped tokens burned
            expect(await omniERC1155.balanceOf(importer2.address, wrappedTokenId)).to.equal(50);
        });
        
        it("Should reject export of non-imported tokens", async function () {
            // Create a native token
            const tx = await omniERC1155.connect(importer1).createToken(
                100,
                0, // FUNGIBLE
                "native-token",
                0
            );
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenCreated");
            const nativeTokenId = event.args.tokenId;
            
            await expect(
                bridge.connect(importer1).exportToChain(
                    nativeTokenId,
                    10,
                    "ethereum",
                    importer1.address
                )
            ).to.be.revertedWith("TokenNotImported");
        });
    });
    
    describe("Gaming Collections", function () {
        it("Should optimize gaming collection imports", async function () {
            const BRIDGE_OPERATOR_ROLE = await bridge.BRIDGE_OPERATOR_ROLE();
            await bridge.grantRole(BRIDGE_OPERATOR_ROLE, owner.address);
            
            const gamingContract = "0xAABBCCDDEEFF001122334455667788990011223";
            
            // Mark as gaming collection
            await bridge.connect(owner).setGamingCollection(gamingContract, true);
            
            // Import gaming asset
            const fee = await bridge.importFees("ethereum");
            const tx = await bridge.connect(importer1).importFromChain(
                gamingContract,
                1001, // Game item ID
                5, // Quantity
                "ethereum",
                "gaming-item",
                { value: fee }
            );
            
            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === "TokenImported");
            const localTokenId = event.args.localTokenId;
            
            // Verify created as SEMI_FUNGIBLE type
            const tokenInfo = await omniERC1155.getTokenInfo(localTokenId);
            expect(tokenInfo.tokenType).to.equal(2); // SEMI_FUNGIBLE
        });
    });
    
    describe("Metadata Management", function () {
        it("Should update cached metadata", async function () {
            const METADATA_ROLE = await bridge.METADATA_ROLE();
            await bridge.grantRole(METADATA_ROLE, owner.address);
            
            const originalContract = "0x1234567890123456789012345678901234567890";
            const tokenId = 200;
            const sourceChain = "polygon";
            
            // Import first
            const fee = await bridge.importFees(sourceChain);
            await bridge.connect(importer1).importFromChain(
                originalContract,
                tokenId,
                10,
                sourceChain,
                "old-metadata",
                { value: fee }
            );
            
            // Update metadata
            const importHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ["address", "uint256", "string"],
                    [originalContract, tokenId, sourceChain]
                )
            );
            
            const newMetadata = {
                uri: "new-metadata-uri",
                name: "Updated Token",
                description: "Updated description",
                cached: true
            };
            
            await expect(
                bridge.connect(owner).updateMetadata(importHash, newMetadata)
            ).to.emit(bridge, "MetadataCached")
            .withArgs(importHash, newMetadata.uri);
            
            const metadata = await bridge.metadataCache(importHash);
            expect(metadata.uri).to.equal(newMetadata.uri);
            expect(metadata.name).to.equal(newMetadata.name);
            expect(metadata.description).to.equal(newMetadata.description);
        });
    });
    
    describe("Admin Functions", function () {
        it("Should pause and unpause bridge", async function () {
            const BRIDGE_OPERATOR_ROLE = await bridge.BRIDGE_OPERATOR_ROLE();
            await bridge.grantRole(BRIDGE_OPERATOR_ROLE, owner.address);
            
            // Pause
            await bridge.connect(owner).pause();
            
            // Should not be able to import
            await expect(
                bridge.connect(importer1).importFromChain(
                    "0x1234567890123456789012345678901234567890",
                    1,
                    10,
                    "ethereum",
                    "test",
                    { value: ethers.utils.parseUnits("10", 6) }
                )
            ).to.be.revertedWith("Pausable: paused");
            
            // Unpause
            await bridge.connect(owner).unpause();
            
            // Should work again
            await expect(
                bridge.connect(importer1).importFromChain(
                    "0x1234567890123456789012345678901234567890",
                    1,
                    10,
                    "ethereum",
                    "test",
                    { value: ethers.utils.parseUnits("10", 6) }
                )
            ).to.not.be.reverted;
        });
        
        it("Should withdraw collected fees", async function () {
            // Perform some imports to collect fees
            const fee = await bridge.importFees("ethereum");
            
            for (let i = 0; i < 3; i++) {
                await bridge.connect(importer1).importFromChain(
                    "0x1234567890123456789012345678901234567890",
                    i,
                    10,
                    "ethereum",
                    `test-${i}`,
                    { value: fee }
                );
            }
            
            const expectedFees = fee.mul(3);
            const balanceBefore = await ethers.provider.getBalance(owner.address);
            
            const tx = await bridge.connect(owner).withdrawFees();
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(tx.gasPrice);
            
            const balanceAfter = await ethers.provider.getBalance(owner.address);
            const received = balanceAfter.sub(balanceBefore).add(gasUsed);
            
            expect(received).to.equal(expectedFees);
        });
    });
});