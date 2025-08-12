const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Dual Token Architecture", function () {
    let owner, user1, user2, treasury;
    let registry, omniCoin, privateOmniCoin, feeManager, bridge;
    
    beforeEach(async function () {
        [owner, user1, user2, treasury] = await ethers.getSigners();
        
        // Deploy Registry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(owner.address);
        await registry.deployed();
        
        // Deploy OmniCoin (public)
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(registry.address);
        await omniCoin.deployed();
        
        // Deploy PrivateOmniCoin
        const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
        privateOmniCoin = await PrivateOmniCoin.deploy(registry.address);
        await privateOmniCoin.deployed();
        
        // Deploy PrivacyFeeManager
        const FeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        feeManager = await FeeManager.deploy(
            omniCoin.address,
            privateOmniCoin.address,
            treasury.address,
            owner.address
        );
        await feeManager.deployed();
        
        // Deploy Bridge
        const Bridge = await ethers.getContractFactory("OmniCoinPrivacyBridge");
        bridge = await Bridge.deploy(
            omniCoin.address,
            privateOmniCoin.address,
            feeManager.address,
            registry.address
        );
        await bridge.deployed();
        
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
            ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OMNICOIN_BRIDGE")),
            bridge.address,
            "Bridge"
        );
        
        // Grant roles
        const BRIDGE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("BRIDGE_ROLE"));
        await privateOmniCoin.grantRole(BRIDGE_ROLE, bridge.address);
        await omniCoin.grantRole(BRIDGE_ROLE, bridge.address);
        
        const FEE_MANAGER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("FEE_MANAGER_ROLE"));
        await feeManager.grantRole(FEE_MANAGER_ROLE, bridge.address);
        
        // Transfer some tokens to users
        const transferAmount = ethers.utils.parseUnits("10000", 6);
        await omniCoin.transfer(user1.address, transferAmount);
        await omniCoin.transfer(user2.address, transferAmount);
    });
    
    describe("Token Properties", function () {
        it("Should have correct names and symbols", async function () {
            expect(await omniCoin.name()).to.equal("OmniCoin");
            expect(await omniCoin.symbol()).to.equal("XOM");
            expect(await privateOmniCoin.name()).to.equal("Private OmniCoin");
            expect(await privateOmniCoin.symbol()).to.equal("pXOM");
        });
        
        it("Should have 6 decimals for COTI compatibility", async function () {
            expect(await omniCoin.decimals()).to.equal(6);
            expect(await privateOmniCoin.decimals()).to.equal(6);
        });
    });
    
    describe("Public Token Operations", function () {
        it("Should allow standard ERC20 transfers", async function () {
            const amount = ethers.utils.parseUnits("100", 6);
            const balanceBefore = await omniCoin.balanceOf(user2.address);
            
            await omniCoin.connect(user1).transfer(user2.address, amount);
            
            const balanceAfter = await omniCoin.balanceOf(user2.address);
            expect(balanceAfter.sub(balanceBefore)).to.equal(amount);
        });
        
        it("Should not charge fees for public transfers", async function () {
            const amount = ethers.utils.parseUnits("100", 6);
            const totalSupplyBefore = await omniCoin.totalSupply();
            
            await omniCoin.connect(user1).transfer(user2.address, amount);
            
            const totalSupplyAfter = await omniCoin.totalSupply();
            expect(totalSupplyAfter).to.equal(totalSupplyBefore);
        });
    });
    
    describe("Bridge Operations", function () {
        it("Should convert public to private tokens with fee", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            
            // Approve bridge
            await omniCoin.connect(user1).approve(bridge.address, amount);
            
            // Get fee
            const bridgeFee = await bridge.bridgeFee();
            const expectedPrivate = amount.mul(10000 - bridgeFee).div(10000);
            
            // Convert
            await bridge.connect(user1).convertToPrivate(amount);
            
            // Check balances
            const publicBalance = await omniCoin.balanceOf(user1.address);
            expect(publicBalance).to.equal(ethers.utils.parseUnits("9000", 6));
            
            // Note: In test mode, we can't directly check private balances
            // but we can verify the event
            const filter = bridge.filters.ConvertedToPrivate(user1.address);
            const events = await bridge.queryFilter(filter);
            expect(events.length).to.equal(1);
            expect(events[0].args.amountOut).to.equal(expectedPrivate);
        });
        
        it("Should convert private to public tokens without fee", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            
            // First convert to private
            await omniCoin.connect(user1).approve(bridge.address, amount);
            await bridge.connect(user1).convertToPrivate(amount);
            
            // Get bridge fee and calculate private tokens received
            const bridgeFee = await bridge.bridgeFee();
            const privateAmount = amount.mul(10000 - bridgeFee).div(10000);
            
            // Convert back to public
            await bridge.connect(user1).convertToPublic(privateAmount);
            
            // Verify event
            const filter = bridge.filters.ConvertedToPublic(user1.address);
            const events = await bridge.queryFilter(filter);
            expect(events.length).to.equal(1);
            expect(events[0].args.amount).to.equal(privateAmount);
        });
    });
    
    describe("Fee Management", function () {
        it("Should calculate fees correctly", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            const operationType = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ESCROW"));
            
            const fee = await feeManager.calculateFee(operationType, amount);
            expect(fee).to.equal(ethers.utils.parseUnits("5", 6)); // 0.5% of 1000
        });
        
        it("Should update fees correctly", async function () {
            const operationType = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ESCROW"));
            
            await feeManager.updateFee(operationType, 100); // 1%
            
            const amount = ethers.utils.parseUnits("1000", 6);
            const fee = await feeManager.calculateFee(operationType, amount);
            expect(fee).to.equal(ethers.utils.parseUnits("10", 6)); // 1% of 1000
        });
    });
    
    describe("Privacy Features", function () {
        it("Should maintain separate token supplies", async function () {
            const publicSupply = await omniCoin.totalSupply();
            const privateSupply = await privateOmniCoin.totalSupply();
            
            // Initially, private supply should be 0
            expect(privateSupply).to.equal(0);
            expect(publicSupply).to.be.gt(0);
        });
        
        it("Should track conversions correctly", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            
            await omniCoin.connect(user1).approve(bridge.address, amount);
            await bridge.connect(user1).convertToPrivate(amount);
            
            const totalConverted = await bridge.totalConvertedToPrivate();
            expect(totalConverted).to.equal(amount);
        });
    });
});