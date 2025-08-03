const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Dual Token Integration Tests", function () {
    let owner, user1, user2, treasury, validator;
    let registry, omniCoin, privateOmniCoin, feeManager, bridge;
    
    // Constants
    const INITIAL_SUPPLY = ethers.utils.parseUnits("100000000", 6); // 100M tokens
    const TEST_AMOUNT = ethers.utils.parseUnits("1000", 6);
    const BRIDGE_FEE = 100; // 1%
    
    beforeEach(async function () {
        [owner, user1, user2, treasury, validator] = await ethers.getSigners();
        
        // 1. Deploy Registry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(owner.address);
        await registry.deployed();
        
        // 2. Deploy OmniCoin (public token)
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(registry.address);
        await omniCoin.deployed();
        
        // 3. Deploy PrivateOmniCoin
        const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
        privateOmniCoin = await PrivateOmniCoin.deploy(registry.address);
        await privateOmniCoin.deployed();
        
        // 4. Deploy PrivacyFeeManager
        const FeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        feeManager = await FeeManager.deploy(
            omniCoin.address,
            privateOmniCoin.address,
            treasury.address,
            owner.address
        );
        await feeManager.deployed();
        
        // 5. Deploy Bridge
        const Bridge = await ethers.getContractFactory("OmniCoinPrivacyBridge");
        bridge = await Bridge.deploy(
            omniCoin.address,
            privateOmniCoin.address,
            feeManager.address,
            registry.address
        );
        await bridge.deployed();
        
        // 6. Register contracts
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
        
        // 7. Grant necessary roles
        const BRIDGE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("BRIDGE_ROLE"));
        await privateOmniCoin.grantRole(BRIDGE_ROLE, bridge.address);
        await omniCoin.grantRole(BRIDGE_ROLE, bridge.address);
        
        const FEE_MANAGER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("FEE_MANAGER_ROLE"));
        await feeManager.grantRole(FEE_MANAGER_ROLE, bridge.address);
        
        // 8. Transfer tokens to test users
        await omniCoin.transfer(user1.address, ethers.utils.parseUnits("10000", 6));
        await omniCoin.transfer(user2.address, ethers.utils.parseUnits("10000", 6));
    });
    
    describe("Initial Setup", function () {
        it("Should deploy all contracts correctly", async function () {
            expect(registry.address).to.not.equal(ethers.constants.AddressZero);
            expect(omniCoin.address).to.not.equal(ethers.constants.AddressZero);
            expect(privateOmniCoin.address).to.not.equal(ethers.constants.AddressZero);
            expect(feeManager.address).to.not.equal(ethers.constants.AddressZero);
            expect(bridge.address).to.not.equal(ethers.constants.AddressZero);
        });
        
        it("Should have correct initial supply", async function () {
            const totalSupply = await omniCoin.totalSupply();
            expect(totalSupply).to.equal(INITIAL_SUPPLY);
        });
        
        it("Should register contracts correctly", async function () {
            const omniAddress = await registry.getContract(
                ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OMNICOIN"))
            );
            expect(omniAddress).to.equal(omniCoin.address);
        });
    });
    
    describe("Public Token (XOM) Operations", function () {
        it("Should transfer tokens without privacy", async function () {
            const balanceBefore = await omniCoin.balanceOf(user2.address);
            
            await omniCoin.connect(user1).transfer(user2.address, TEST_AMOUNT);
            
            const balanceAfter = await omniCoin.balanceOf(user2.address);
            expect(balanceAfter.sub(balanceBefore)).to.equal(TEST_AMOUNT);
        });
        
        it("Should not charge fees for basic transfers", async function () {
            const treasuryBefore = await omniCoin.balanceOf(treasury.address);
            
            await omniCoin.connect(user1).transfer(user2.address, TEST_AMOUNT);
            
            const treasuryAfter = await omniCoin.balanceOf(treasury.address);
            expect(treasuryAfter).to.equal(treasuryBefore);
        });
    });
    
    describe("Bridge Conversion XOM → pXOM", function () {
        it("Should convert public to private with correct fee", async function () {
            // Approve bridge
            await omniCoin.connect(user1).approve(bridge.address, TEST_AMOUNT);
            
            // Calculate expected amounts
            const fee = TEST_AMOUNT.mul(BRIDGE_FEE).div(10000);
            const expectedPrivate = TEST_AMOUNT.sub(fee);
            
            // Convert
            const tx = await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
            const receipt = await tx.wait();
            
            // Check event
            const event = receipt.events.find(e => e.event === "ConvertedToPrivate");
            expect(event).to.not.be.undefined;
            expect(event.args.user).to.equal(user1.address);
            expect(event.args.amountIn).to.equal(TEST_AMOUNT);
            expect(event.args.amountOut).to.equal(expectedPrivate);
            expect(event.args.fee).to.equal(fee);
        });
        
        it("Should lock XOM in bridge", async function () {
            await omniCoin.connect(user1).approve(bridge.address, TEST_AMOUNT);
            
            const bridgeBalanceBefore = await omniCoin.balanceOf(bridge.address);
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
            const bridgeBalanceAfter = await omniCoin.balanceOf(bridge.address);
            
            expect(bridgeBalanceAfter.sub(bridgeBalanceBefore)).to.equal(TEST_AMOUNT);
        });
        
        it("Should track total conversions", async function () {
            await omniCoin.connect(user1).approve(bridge.address, TEST_AMOUNT);
            
            const totalBefore = await bridge.totalConvertedToPrivate();
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
            const totalAfter = await bridge.totalConvertedToPrivate();
            
            expect(totalAfter.sub(totalBefore)).to.equal(TEST_AMOUNT);
        });
    });
    
    describe("Bridge Conversion pXOM → XOM", function () {
        beforeEach(async function () {
            // First convert some XOM to pXOM
            await omniCoin.connect(user1).approve(bridge.address, TEST_AMOUNT);
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
        });
        
        it("Should convert private to public without fee", async function () {
            const fee = TEST_AMOUNT.mul(BRIDGE_FEE).div(10000);
            const privateAmount = TEST_AMOUNT.sub(fee);
            
            const balanceBefore = await omniCoin.balanceOf(user1.address);
            
            const tx = await bridge.connect(user1).convertToPublic(privateAmount);
            const receipt = await tx.wait();
            
            const balanceAfter = await omniCoin.balanceOf(user1.address);
            expect(balanceAfter.sub(balanceBefore)).to.equal(privateAmount);
            
            // Check event
            const event = receipt.events.find(e => e.event === "ConvertedToPublic");
            expect(event).to.not.be.undefined;
            expect(event.args.user).to.equal(user1.address);
            expect(event.args.amount).to.equal(privateAmount);
        });
        
        it("Should maintain 1:1 backing", async function () {
            // Get initial state
            const bridgeBalance = await omniCoin.balanceOf(bridge.address);
            const privateSupply = await privateOmniCoin.publicTotalSupply();
            
            // Bridge balance should equal private supply + fees collected
            const totalFees = await bridge.totalFeesCollected();
            expect(bridgeBalance).to.equal(privateSupply.add(totalFees));
        });
    });
    
    describe("Fee Management", function () {
        it("Should calculate operation fees correctly", async function () {
            const escrowFee = await feeManager.calculateFee(
                ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ESCROW")),
                TEST_AMOUNT
            );
            expect(escrowFee).to.equal(TEST_AMOUNT.mul(50).div(10000)); // 0.5%
        });
        
        it("Should collect public fees", async function () {
            // Grant role to test account
            const FEE_MANAGER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("FEE_MANAGER_ROLE"));
            await feeManager.grantRole(FEE_MANAGER_ROLE, owner.address);
            
            // Approve fee payment
            const feeAmount = TEST_AMOUNT.mul(50).div(10000);
            await omniCoin.connect(user1).approve(feeManager.address, feeAmount);
            
            const treasuryBefore = await omniCoin.balanceOf(treasury.address);
            
            await feeManager.collectPublicFee(
                user1.address,
                ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ESCROW")),
                TEST_AMOUNT
            );
            
            const treasuryAfter = await omniCoin.balanceOf(treasury.address);
            expect(treasuryAfter.sub(treasuryBefore)).to.equal(feeAmount);
        });
    });
    
    describe("Privacy Features", function () {
        it("Should maintain separate token identities", async function () {
            const xomName = await omniCoin.name();
            const xomSymbol = await omniCoin.symbol();
            const pxomName = await privateOmniCoin.name();
            const pxomSymbol = await privateOmniCoin.symbol();
            
            expect(xomName).to.equal("OmniCoin");
            expect(xomSymbol).to.equal("XOM");
            expect(pxomName).to.equal("Private OmniCoin");
            expect(pxomSymbol).to.equal("pXOM");
        });
        
        it("Should handle MPC availability flag", async function () {
            const isMpcAvailable = await privateOmniCoin.isMpcAvailable();
            expect(isMpcAvailable).to.be.false; // Disabled for testing
            
            // Admin can enable MPC
            await privateOmniCoin.setMpcAvailability(true);
            expect(await privateOmniCoin.isMpcAvailable()).to.be.true;
        });
    });
    
    describe("Edge Cases", function () {
        it("Should reject zero amount conversions", async function () {
            await expect(
                bridge.connect(user1).convertToPrivate(0)
            ).to.be.revertedWith("InvalidAmount");
        });
        
        it("Should reject conversions without approval", async function () {
            await expect(
                bridge.connect(user1).convertToPrivate(TEST_AMOUNT)
            ).to.be.reverted;
        });
        
        it("Should handle pause functionality", async function () {
            // Pause bridge
            const PAUSER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PAUSER_ROLE"));
            await bridge.pause();
            
            // Try to convert
            await omniCoin.connect(user1).approve(bridge.address, TEST_AMOUNT);
            await expect(
                bridge.connect(user1).convertToPrivate(TEST_AMOUNT)
            ).to.be.revertedWith("Pausable: paused");
            
            // Unpause and retry
            await bridge.unpause();
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
        });
    });
});