const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ListingNFT", function () {
    let owner, minter1, minter2, buyer1, buyer2, treasury;
    let registry, omniCoin, privateOmniCoin;
    let listingNFT;
    
    // Transaction status enum
    const TransactionStatus = {
        Pending: 0,
        Completed: 1,
        Cancelled: 2
    };
    
    beforeEach(async function () {
        [owner, minter1, minter2, buyer1, buyer2, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test since actual PrivateOmniCoin requires MPC
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
            await owner.getAddress()
        );
        
        // Deploy ListingNFT
        const ListingNFT = await ethers.getContractFactory("ListingNFT");
        listingNFT = await ListingNFT.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await listingNFT.waitForDeployment();
    });
    
    describe("Deployment", function () {
        it("Should set the correct name and symbol", async function () {
            expect(await listingNFT.name()).to.equal("OmniBazaar Listing");
            expect(await listingNFT.symbol()).to.equal("OBL");
        });
        
        it("Should set the owner correctly", async function () {
            expect(await listingNFT.owner()).to.equal(await owner.getAddress());
        });
    });
    
    describe("Minter Management", function () {
        it("Should allow owner to approve minters", async function () {
            await listingNFT.connect(owner).setApprovedMinter(await minter1.getAddress(), true);
            expect(await listingNFT.isApprovedMinter(await minter1.getAddress())).to.be.true;
        });
        
        it("Should allow owner to revoke minter approval", async function () {
            await listingNFT.connect(owner).setApprovedMinter(await minter1.getAddress(), true);
            await listingNFT.connect(owner).setApprovedMinter(await minter1.getAddress(), false);
            expect(await listingNFT.isApprovedMinter(await minter1.getAddress())).to.be.false;
        });
        
        it("Should emit MinterApprovalChanged event", async function () {
            await expect(listingNFT.connect(owner).setApprovedMinter(await minter1.getAddress(), true))
                .to.emit(listingNFT, "MinterApprovalChanged")
                .withArgs(await minter1.getAddress(), true);
        });
        
        it("Should not allow non-owner to approve minters", async function () {
            await expect(
                listingNFT.connect(minter1).setApprovedMinter(await minter2.getAddress(), true)
            ).to.be.revertedWithCustomError(listingNFT, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Minting", function () {
        const tokenURI = "ipfs://QmTest123";
        
        it("Should allow approved minter to mint", async function () {
            await listingNFT.connect(owner).setApprovedMinter(await minter1.getAddress(), true);
            
            const tx = await listingNFT.connect(minter1).mint(await minter1.getAddress(), tokenURI);
            const receipt = await tx.wait();
            
            expect(await listingNFT.ownerOf(1)).to.equal(await minter1.getAddress());
            expect(await listingNFT.tokenURI(1)).to.equal(tokenURI);
        });
        
        it("Should allow owner to mint", async function () {
            await listingNFT.connect(owner).mint(await buyer1.getAddress(), tokenURI);
            
            expect(await listingNFT.ownerOf(1)).to.equal(await buyer1.getAddress());
            expect(await listingNFT.tokenURI(1)).to.equal(tokenURI);
        });
        
        it("Should track user listings", async function () {
            await listingNFT.connect(owner).mint(await buyer1.getAddress(), tokenURI);
            await listingNFT.connect(owner).mint(await buyer1.getAddress(), tokenURI + "2");
            
            const listings = await listingNFT.getUserListings(await buyer1.getAddress());
            expect(listings.length).to.equal(2);
            expect(listings[0]).to.equal(1);
            expect(listings[1]).to.equal(2);
        });
        
        it("Should not allow unapproved minter to mint", async function () {
            await expect(
                listingNFT.connect(minter1).mint(await minter1.getAddress(), tokenURI)
            ).to.be.revertedWithCustomError(listingNFT, "NotAuthorizedToMint");
        });
        
        it("Should increment token IDs correctly", async function () {
            await listingNFT.connect(owner).mint(await buyer1.getAddress(), "uri1");
            await listingNFT.connect(owner).mint(await buyer2.getAddress(), "uri2");
            
            expect(await listingNFT.ownerOf(1)).to.equal(await buyer1.getAddress());
            expect(await listingNFT.ownerOf(2)).to.equal(await buyer2.getAddress());
        });
    });
    
    describe("Transaction Management", function () {
        beforeEach(async function () {
            // Mint a token first
            await listingNFT.connect(owner).mint(await minter1.getAddress(), "ipfs://listing");
        });
        
        it("Should create a transaction with public payment", async function () {
            const tokenId = 1;
            const price = ethers.parseUnits("100", 6);
            const quantity = 1;
            
            await expect(
                listingNFT.connect(minter1).createTransaction(
                    tokenId,
                    await buyer1.getAddress(),
                    quantity,
                    price,
                    false // usePrivacy
                )
            ).to.emit(listingNFT, "TransactionCreated")
                .withArgs(tokenId, await minter1.getAddress(), await buyer1.getAddress(), price, quantity);
            
            const transaction = await listingNFT.getTransaction(tokenId);
            expect(transaction.seller).to.equal(await minter1.getAddress());
            expect(transaction.buyer).to.equal(await buyer1.getAddress());
            expect(transaction.price).to.equal(price);
            expect(transaction.quantity).to.equal(quantity);
            expect(transaction.status).to.equal(TransactionStatus.Pending);
            expect(transaction.usePrivacy).to.be.false;
            expect(transaction.paymentToken).to.equal(await mockOmniCoin.getAddress());
        });
        
        it("Should create a transaction with private payment", async function () {
            const tokenId = 1;
            const price = ethers.parseUnits("100", 6);
            
            await listingNFT.connect(minter1).createTransaction(
                tokenId,
                await buyer1.getAddress(),
                1,
                price,
                true // usePrivacy
            );
            
            const transaction = await listingNFT.getTransaction(tokenId);
            expect(transaction.usePrivacy).to.be.true;
            expect(transaction.paymentToken).to.equal(await mockPrivateOmniCoin.getAddress());
        });
        
        it("Should not allow non-owner to create transaction", async function () {
            await expect(
                listingNFT.connect(buyer1).createTransaction(1, await buyer2.getAddress(), 1, 100, false)
            ).to.be.revertedWithCustomError(listingNFT, "NotListingOwner");
        });
        
        it("Should not allow self-purchase", async function () {
            await expect(
                listingNFT.connect(minter1).createTransaction(1, await minter1.getAddress(), 1, 100, false)
            ).to.be.revertedWithCustomError(listingNFT, "CannotBuyOwnListing");
        });
        
        it("Should not create transaction for non-existent token", async function () {
            await expect(
                listingNFT.connect(owner).createTransaction(999, await buyer1.getAddress(), 1, 100, false)
            ).to.be.revertedWithCustomError(listingNFT, "ListingDoesNotExist");
        });
        
        it("Should track user transactions", async function () {
            await listingNFT.connect(minter1).createTransaction(1, await buyer1.getAddress(), 1, 100, false);
            
            const transactions = await listingNFT.getUserTransactions(await buyer1.getAddress());
            expect(transactions.length).to.equal(1);
            expect(transactions[0]).to.equal(1);
        });
    });
    
    describe("Transaction Status Updates", function () {
        beforeEach(async function () {
            await listingNFT.connect(owner).mint(await minter1.getAddress(), "ipfs://listing");
            await listingNFT.connect(minter1).createTransaction(
                1,
                await buyer1.getAddress(),
                1,
                ethers.parseUnits("100", 6),
                false
            );
        });
        
        it("Should allow seller to update transaction status", async function () {
            await expect(
                listingNFT.connect(minter1).updateTransactionStatus(1, TransactionStatus.Completed)
            ).to.emit(listingNFT, "TransactionStatusChanged")
                .withArgs(1, await minter1.getAddress(), await buyer1.getAddress(), TransactionStatus.Completed);
            
            const transaction = await listingNFT.getTransaction(1);
            expect(transaction.status).to.equal(TransactionStatus.Completed);
        });
        
        it("Should allow buyer to update transaction status", async function () {
            await listingNFT.connect(buyer1).updateTransactionStatus(1, TransactionStatus.Cancelled);
            
            const transaction = await listingNFT.getTransaction(1);
            expect(transaction.status).to.equal(TransactionStatus.Cancelled);
        });
        
        it("Should not allow unauthorized party to update status", async function () {
            await expect(
                listingNFT.connect(buyer2).updateTransactionStatus(1, TransactionStatus.Completed)
            ).to.be.revertedWithCustomError(listingNFT, "NotAuthorized");
        });
    });
    
    describe("Escrow Integration", function () {
        beforeEach(async function () {
            await listingNFT.connect(owner).mint(await minter1.getAddress(), "ipfs://listing");
            await listingNFT.connect(minter1).createTransaction(
                1,
                await buyer1.getAddress(),
                1,
                ethers.parseUnits("100", 6),
                false
            );
        });
        
        it("Should allow setting escrow ID", async function () {
            const escrowId = "ESCROW123";
            
            await listingNFT.connect(minter1).setEscrowId(1, escrowId);
            
            const transaction = await listingNFT.getTransaction(1);
            expect(transaction.escrowId).to.equal(escrowId);
        });
        
        it("Should only allow seller or buyer to set escrow ID", async function () {
            await expect(
                listingNFT.connect(buyer2).setEscrowId(1, "ESCROW123")
            ).to.be.revertedWithCustomError(listingNFT, "NotAuthorized");
        });
    });
    
    describe("Transfer Restrictions", function () {
        beforeEach(async function () {
            await listingNFT.connect(owner).mint(await minter1.getAddress(), "ipfs://listing");
        });
        
        it("Should allow transfer when no pending transaction", async function () {
            await listingNFT.connect(minter1).transferFrom(
                await minter1.getAddress(),
                await buyer1.getAddress(),
                1
            );
            
            expect(await listingNFT.ownerOf(1)).to.equal(await buyer1.getAddress());
        });
        
        it("Should prevent transfer during pending transaction", async function () {
            // Create a pending transaction
            await listingNFT.connect(minter1).createTransaction(
                1,
                await buyer1.getAddress(),
                1,
                100,
                false
            );
            
            // Try to transfer
            await expect(
                listingNFT.connect(minter1).transferFrom(
                    await minter1.getAddress(),
                    await buyer2.getAddress(),
                    1
                )
            ).to.be.revertedWithCustomError(listingNFT, "CannotTransferPendingTransaction");
        });
        
        it("Should allow transfer after transaction completion", async function () {
            // Create and complete a transaction
            await listingNFT.connect(minter1).createTransaction(
                1,
                await buyer1.getAddress(),
                1,
                100,
                false
            );
            await listingNFT.connect(minter1).updateTransactionStatus(1, TransactionStatus.Completed);
            
            // Now transfer should work
            await listingNFT.connect(minter1).transferFrom(
                await minter1.getAddress(),
                await buyer2.getAddress(),
                1
            );
            
            expect(await listingNFT.ownerOf(1)).to.equal(await buyer2.getAddress());
        });
    });
    
    describe("Payment Token Verification", function () {
        beforeEach(async function () {
            await listingNFT.connect(owner).mint(await minter1.getAddress(), "ipfs://listing");
            await listingNFT.connect(minter1).createTransaction(
                1,
                await buyer1.getAddress(),
                1,
                100,
                false
            );
        });
        
        it("Should correctly identify OmniCoin payment", async function () {
            const [isOmniPayment, paymentToken] = await listingNFT.isOmniCoinPayment(1);
            
            expect(isOmniPayment).to.be.true;
            expect(paymentToken).to.equal(await mockOmniCoin.getAddress());
        });
        
        it("Should correctly identify PrivateOmniCoin payment", async function () {
            // Create transaction with privacy
            await listingNFT.connect(owner).mint(await minter1.getAddress(), "ipfs://listing2");
            await listingNFT.connect(minter1).createTransaction(
                2,
                await buyer1.getAddress(),
                1,
                100,
                true // usePrivacy
            );
            
            const [isOmniPayment, paymentToken] = await listingNFT.isOmniCoinPayment(2);
            
            expect(isOmniPayment).to.be.true;
            expect(paymentToken).to.equal(await mockPrivateOmniCoin.getAddress());
        });
    });
});