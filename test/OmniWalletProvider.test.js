const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniWalletProvider", function () {
    let owner, user1, user2, user3, arbitrator, treasury;
    let provider;
    let registry, omniCoin, privateOmniCoin;
    let listingNFT, escrow, bridge, privacy, account, validator, garbledCircuit, privacyFeeManager, identityVerification, reputationCore;
    
    beforeEach(async function () {
        [owner, user1, user2, user3, arbitrator, treasury] = await ethers.getSigners();
        
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
        
        // Deploy actual ListingNFT
        const ListingNFT = await ethers.getContractFactory("ListingNFT");
        listingNFT = await ListingNFT.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await listingNFT.waitForDeployment();
        
        // Deploy actual OmniCoinEscrow
        const OmniCoinEscrow = await ethers.getContractFactory("OmniCoinEscrow");
        escrow = await OmniCoinEscrow.deploy(
            await registry.getAddress(),
            await arbitrator.getAddress()
        );
        await escrow.waitForDeployment();
        
        // Deploy actual PrivacyFeeManager (needed for bridge)
        const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        privacyFeeManager = await PrivacyFeeManager.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await privacyFeeManager.waitForDeployment();
        
        // Deploy actual OmniCoinBridge
        const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
        bridge = await OmniCoinBridge.deploy(
            await registry.getAddress(),
            await omniCoin.getAddress(),
            await owner.getAddress(),
            await privacyFeeManager.getAddress()
        );
        await bridge.waitForDeployment();
        
        // Deploy actual OmniCoinGarbledCircuit (needed for privacy)
        const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
        garbledCircuit = await OmniCoinGarbledCircuit.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await garbledCircuit.waitForDeployment();
        
        // Deploy actual OmniCoinPrivacy
        const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
        privacy = await OmniCoinPrivacy.deploy(
            await registry.getAddress(),
            await privateOmniCoin.getAddress()
        );
        await privacy.waitForDeployment();
        
        // Deploy actual OmniCoinAccount
        const OmniCoinAccount = await ethers.getContractFactory("OmniCoinAccount");
        account = await OmniCoinAccount.deploy();
        await account.waitForDeployment();
        await account.initialize(
            await user1.getAddress(),
            await registry.getAddress()
        );
        
        // Deploy actual OmniCoinValidator
        const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
        validator = await OmniCoinValidator.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await validator.waitForDeployment();
        
        // Deploy actual IdentityVerification (needed for _getUsername)
        const IdentityVerification = await ethers.getContractFactory("IdentityVerification");
        identityVerification = await IdentityVerification.deploy(
            await registry.getAddress()
        );
        await identityVerification.waitForDeployment();
        
        // Deploy actual ReputationCore (needed for _getReputationScore)
        const ReputationCore = await ethers.getContractFactory("ReputationCore");
        reputationCore = await ReputationCore.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await reputationCore.waitForDeployment();
        
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
            ethers.keccak256(ethers.toUtf8Bytes("LISTING_NFT")),
            await listingNFT.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("ESCROW")),
            await escrow.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_BRIDGE")),
            await bridge.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_PRIVACY")),
            await privacy.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_ACCOUNT")),
            await account.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_VALIDATOR")),
            await validator.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("GARBLED_CIRCUIT")),
            await garbledCircuit.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("IDENTITY_VERIFICATION")),
            await identityVerification.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("REPUTATION_CORE")),
            await reputationCore.getAddress()
        );
        
        // Deploy OmniWalletProvider
        const OmniWalletProvider = await ethers.getContractFactory("OmniWalletProvider");
        provider = await OmniWalletProvider.deploy();
        await provider.waitForDeployment();
        
        // Initialize provider
        await provider.initialize(await registry.getAddress());
        
        // Fund users with tokens
        await omniCoin.mint(await user1.getAddress(), ethers.parseUnits("10000", 6));
        await omniCoin.mint(await user2.getAddress(), ethers.parseUnits("5000", 6));
        await privateOmniCoin.mint(await user1.getAddress(), ethers.parseUnits("5000", 6));
    });
    
    describe("Deployment and Initialization", function () {
        it("Should set correct initial values", async function () {
            expect(await provider.owner()).to.equal(await owner.getAddress());
            expect(await provider.sessionDuration()).to.equal(24 * 60 * 60); // 24 hours
            expect(await provider.sessionCounter()).to.equal(0);
            expect(await provider.registry()).to.equal(await registry.getAddress());
        });
        
        it("Should not allow reinitialization", async function () {
            await expect(
                provider.initialize(await registry.getAddress())
            ).to.be.revertedWith("Initializable: contract is already initialized");
        });
    });
    
    describe("Wallet Information", function () {
        it("Should get comprehensive wallet information", async function () {
            const walletInfo = await provider.getWalletInfo(await user1.getAddress());
            
            expect(walletInfo.walletAddress).to.equal(await user1.getAddress());
            expect(walletInfo.balance).to.equal(ethers.parseUnits("10000", 6));
            expect(walletInfo.privacyEnabled).to.be.false;
            expect(walletInfo.username).to.equal("");
            expect(walletInfo.nftCount).to.equal(0);
            expect(walletInfo.pendingTransactions).to.equal(0);
            expect(walletInfo.stakedAmount).to.equal(0);
            expect(walletInfo.reputationScore).to.equal(0);
        });
        
        it("Should reflect NFT ownership in wallet info", async function () {
            // Mint NFT for user
            await listingNFT.mint(
                await user1.getAddress(),
                "https://example.com/nft/1"
            );
            
            const walletInfo = await provider.getWalletInfo(await user1.getAddress());
            expect(walletInfo.nftCount).to.equal(1);
        });
    });
    
    describe("Session Management", function () {
        it("Should create wallet session", async function () {
            const tx = await provider.connect(user1).createSession(await user1.getAddress());
            const receipt = await tx.wait();
            
            // Check events
            const event = receipt.logs.find(
                log => log.fragment && log.fragment.name === "SessionCreated"
            );
            expect(event).to.not.be.undefined;
            
            const sessionId = 1;
            expect(await provider.sessionCounter()).to.equal(sessionId);
            
            // Check session validity
            expect(await provider.isValidSession(await user1.getAddress())).to.be.true;
        });
        
        it("Should not allow creating session for another wallet", async function () {
            await expect(
                provider.connect(user1).createSession(await user2.getAddress())
            ).to.be.revertedWithCustomError(provider, "UnauthorizedSessionCreation");
        });
        
        it("Should expire session after duration", async function () {
            await provider.connect(user1).createSession(await user1.getAddress());
            expect(await provider.isValidSession(await user1.getAddress())).to.be.true;
            
            // Fast forward past session duration
            await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 1]);
            await ethers.provider.send("evm_mine");
            
            expect(await provider.isValidSession(await user1.getAddress())).to.be.false;
        });
        
        it("Should update session duration", async function () {
            const newDuration = 12 * 60 * 60; // 12 hours
            await provider.connect(owner).updateSessionDuration(newDuration);
            expect(await provider.sessionDuration()).to.equal(newDuration);
        });
    });
    
    describe("Quick Send", function () {
        beforeEach(async function () {
            // Approve provider to spend tokens
            await omniCoin.connect(user1).approve(
                await provider.getAddress(),
                ethers.parseUnits("10000", 6)
            );
        });
        
        it("Should execute quick send without privacy", async function () {
            const amount = ethers.parseUnits("100", 6);
            const balanceBefore = await omniCoin.balanceOf(await user2.getAddress());
            
            await expect(
                provider.connect(user1).quickSend(
                    await user2.getAddress(),
                    amount,
                    false
                )
            ).to.not.be.reverted;
            
            const balanceAfter = await omniCoin.balanceOf(await user2.getAddress());
            expect(balanceAfter - balanceBefore).to.equal(amount);
        });
        
        it("Should execute quick send with privacy", async function () {
            const amount = ethers.parseUnits("100", 6);
            
            // Mock privacy expects deposit and transfer calls
            await expect(
                provider.connect(user1).quickSend(
                    await user2.getAddress(),
                    amount,
                    true
                )
            ).to.not.be.reverted;
        });
        
        it("Should reject quick send to zero address", async function () {
            await expect(
                provider.connect(user1).quickSend(
                    ethers.ZeroAddress,
                    ethers.parseUnits("100", 6),
                    false
                )
            ).to.be.revertedWithCustomError(provider, "InvalidRecipient");
        });
        
        it("Should reject quick send with zero amount", async function () {
            await expect(
                provider.connect(user1).quickSend(
                    await user2.getAddress(),
                    0,
                    false
                )
            ).to.be.revertedWithCustomError(provider, "InvalidAmount");
        });
    });
    
    describe("NFT Listing", function () {
        it("Should create NFT listing", async function () {
            const tokenURI = "https://example.com/nft/metadata.json";
            const price = ethers.parseUnits("100", 6);
            const quantity = 5;
            
            await expect(
                provider.connect(user1).createNFTListing(
                    tokenURI,
                    await user2.getAddress(),
                    price,
                    quantity
                )
            ).to.not.be.reverted;
            
            // Check NFT was minted
            const nftCount = await listingNFT.getUserListings(await user1.getAddress());
            expect(nftCount.length).to.equal(1);
        });
        
        it("Should get NFT portfolio", async function () {
            // Create multiple NFT listings
            for (let i = 0; i < 3; i++) {
                await provider.connect(user1).createNFTListing(
                    `https://example.com/nft/${i}`,
                    await user2.getAddress(),
                    ethers.parseUnits("100", 6),
                    1
                );
            }
            
            const portfolio = await provider.getNFTPortfolio(await user1.getAddress());
            expect(portfolio.tokenIds.length).to.equal(3);
            expect(portfolio.tokenURIs.length).to.equal(3);
            expect(portfolio.transactionCounts.length).to.equal(3);
            
            // Check URIs
            for (let i = 0; i < 3; i++) {
                expect(portfolio.tokenURIs[i]).to.equal(`https://example.com/nft/${i}`);
                expect(portfolio.transactionCounts[i]).to.equal(1);
            }
        });
    });
    
    describe("Marketplace Escrow", function () {
        it("Should create marketplace escrow", async function () {
            const amount = ethers.parseUnits("500", 6);
            const duration = 7 * 24 * 60 * 60; // 7 days
            
            await expect(
                provider.connect(user1).createMarketplaceEscrow(
                    await user2.getAddress(),
                    await arbitrator.getAddress(),
                    amount,
                    duration
                )
            ).to.not.be.reverted;
        });
    });
    
    describe("Cross-Chain Transfer", function () {
        it("Should initiate cross-chain transfer", async function () {
            const targetChainId = 137; // Polygon
            const amount = ethers.parseUnits("1000", 6);
            
            await expect(
                provider.connect(user1).initiateCrossChainTransfer(
                    targetChainId,
                    await omniCoin.getAddress(), // Target token
                    await user2.getAddress(),
                    amount
                )
            ).to.not.be.reverted;
        });
        
        it("Should get cross-chain history", async function () {
            const history = await provider.getCrossChainHistory(await user1.getAddress());
            
            expect(history.transferIds.length).to.equal(0);
            expect(history.amounts.length).to.equal(0);
            expect(history.targetChains.length).to.equal(0);
            expect(history.completed.length).to.equal(0);
        });
    });
    
    describe("Privacy Features", function () {
        it("Should enable privacy for wallet", async function () {
            const tx = await provider.connect(user1).enablePrivacy();
            const receipt = await tx.wait();
            
            // Should return a commitment hash
            expect(receipt).to.not.be.null;
        });
    });
    
    describe("Gas Estimation", function () {
        it("Should estimate gas for valid transaction", async function () {
            const target = await omniCoin.getAddress();
            const data = omniCoin.interface.encodeFunctionData("transfer", [
                await user2.getAddress(),
                ethers.parseUnits("100", 6)
            ]);
            
            const estimate = await provider.estimateGas(target, data, 0);
            
            expect(estimate.gasEstimate).to.be.gt(0);
            expect(estimate.canExecute).to.be.true;
            expect(estimate.errorMessage).to.equal("");
        });
        
        it("Should fail gas estimation for invalid target", async function () {
            await expect(
                provider.simulateTransaction(ethers.ZeroAddress, "0x", 0)
            ).to.be.revertedWithCustomError(provider, "InvalidTarget");
        });
    });
    
    describe("Wallet Authorization", function () {
        it("Should authorize wallet", async function () {
            await expect(provider.connect(owner).authorizeWallet(await user1.getAddress()))
                .to.emit(provider, "WalletAuthorized")
                .withArgs(await user1.getAddress());
            
            expect(await provider.authorizedWallets(await user1.getAddress())).to.be.true;
        });
        
        it("Should deauthorize wallet", async function () {
            await provider.connect(owner).authorizeWallet(await user1.getAddress());
            
            await expect(provider.connect(owner).deauthorizeWallet(await user1.getAddress()))
                .to.emit(provider, "WalletDeauthorized")
                .withArgs(await user1.getAddress());
            
            expect(await provider.authorizedWallets(await user1.getAddress())).to.be.false;
        });
        
        it("Should only allow owner to authorize", async function () {
            await expect(
                provider.connect(user1).authorizeWallet(await user2.getAddress())
            ).to.be.revertedWithCustomError(provider, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Nonce Management", function () {
        it("Should get current nonce for wallet", async function () {
            expect(await provider.getCurrentNonce(await user1.getAddress())).to.equal(0);
        });
    });
});