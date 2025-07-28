const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinPrivacyBridge", function () {
    let owner, feeManager, pauser, user1, user2, treasury;
    let bridge;
    let registry, omniCoin, privateOmniCoin, privacyFeeManager;
    
    // Constants
    const INITIAL_SUPPLY = ethers.parseUnits("1000000", 6);
    const BASIS_POINTS = 10000n;
    const DEFAULT_BRIDGE_FEE = 100n; // 1%
    const MAX_BRIDGE_FEE = 200n; // 2%
    
    // Roles
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
    const FEE_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("FEE_MANAGER_ROLE"));
    
    beforeEach(async function () {
        [owner, feeManager, pauser, user1, user2, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test with mint/burn
        const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        privateOmniCoin = await StandardERC20Test.deploy();
        await privateOmniCoin.waitForDeployment();
        
        // Deploy actual PrivacyFeeManager
        const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        privacyFeeManager = await PrivacyFeeManager.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await privacyFeeManager.waitForDeployment();
        
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
            await treasury.getAddress()
        );
        
        // Deploy OmniCoinPrivacyBridge
        const OmniCoinPrivacyBridge = await ethers.getContractFactory("OmniCoinPrivacyBridge");
        bridge = await OmniCoinPrivacyBridge.deploy(
            await omniCoin.getAddress(),
            await privateOmniCoin.getAddress(),
            await privacyFeeManager.getAddress(),
            await registry.getAddress()
        );
        await bridge.waitForDeployment();
        
        // Grant minter role to bridge for PrivateOmniCoin
        await privateOmniCoin.grantRole(
            ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE")),
            await bridge.getAddress()
        );
        
        // Grant burner role to bridge for PrivateOmniCoin
        await privateOmniCoin.grantRole(
            ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE")),
            await bridge.getAddress()
        );
        
        // Grant roles
        await bridge.grantRole(FEE_MANAGER_ROLE, await feeManager.getAddress());
        await bridge.grantRole(PAUSER_ROLE, await pauser.getAddress());
        
        // Fund users with OmniCoin
        await omniCoin.mint(await user1.getAddress(), ethers.parseUnits("10000", 6));
        await omniCoin.mint(await user2.getAddress(), ethers.parseUnits("5000", 6));
        
        // Approve bridge to spend tokens
        await omniCoin.connect(user1).approve(
            await bridge.getAddress(),
            ethers.MaxUint256
        );
        await omniCoin.connect(user2).approve(
            await bridge.getAddress(),
            ethers.MaxUint256
        );
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await bridge.OMNI_COIN()).to.equal(await omniCoin.getAddress());
            expect(await bridge.PRIVATE_OMNI_COIN()).to.equal(await privateOmniCoin.getAddress());
            expect(await bridge.PRIVACY_FEE_MANAGER()).to.equal(await privacyFeeManager.getAddress());
            expect(await bridge.bridgeFee()).to.equal(DEFAULT_BRIDGE_FEE);
            expect(await bridge.totalFeesCollected()).to.equal(0);
            expect(await bridge.totalConvertedToPrivate()).to.equal(0);
            expect(await bridge.totalConvertedToPublic()).to.equal(0);
        });
        
        it("Should have correct roles assigned", async function () {
            expect(await bridge.hasRole(DEFAULT_ADMIN_ROLE, await owner.getAddress())).to.be.true;
            expect(await bridge.hasRole(PAUSER_ROLE, await owner.getAddress())).to.be.true;
            expect(await bridge.hasRole(FEE_MANAGER_ROLE, await owner.getAddress())).to.be.true;
            expect(await bridge.hasRole(FEE_MANAGER_ROLE, await feeManager.getAddress())).to.be.true;
            expect(await bridge.hasRole(PAUSER_ROLE, await pauser.getAddress())).to.be.true;
        });
    });
    
    describe("Convert to Private", function () {
        it("Should convert OmniCoin to PrivateOmniCoin with fee", async function () {
            const amount = ethers.parseUnits("1000", 6);
            const expectedFee = (amount * DEFAULT_BRIDGE_FEE) / BASIS_POINTS;
            const expectedOutput = amount - expectedFee;
            
            const omniBalanceBefore = await omniCoin.balanceOf(await user1.getAddress());
            const privateBalanceBefore = await privateOmniCoin.balanceOf(await user1.getAddress());
            
            await expect(bridge.connect(user1).convertToPrivate(amount))
                .to.emit(bridge, "ConvertedToPrivate")
                .withArgs(await user1.getAddress(), amount, expectedOutput, expectedFee);
            
            const omniBalanceAfter = await omniCoin.balanceOf(await user1.getAddress());
            const privateBalanceAfter = await privateOmniCoin.balanceOf(await user1.getAddress());
            
            expect(omniBalanceBefore - omniBalanceAfter).to.equal(amount);
            expect(privateBalanceAfter - privateBalanceBefore).to.equal(expectedOutput);
            
            // Check bridge statistics
            expect(await bridge.totalFeesCollected()).to.equal(expectedFee);
            expect(await bridge.totalConvertedToPrivate()).to.equal(amount);
            
            // Check bridge holds the OmniCoin
            expect(await omniCoin.balanceOf(await bridge.getAddress())).to.equal(amount);
        });
        
        it("Should calculate correct fee amounts", async function () {
            const testAmounts = [
                ethers.parseUnits("100", 6),
                ethers.parseUnits("1000", 6),
                ethers.parseUnits("10000", 6)
            ];
            
            for (const amount of testAmounts) {
                const [fee, amountOut] = await bridge.calculateConversionFee(amount);
                expect(fee).to.equal((amount * DEFAULT_BRIDGE_FEE) / BASIS_POINTS);
                expect(amountOut).to.equal(amount - fee);
            }
        });
        
        it("Should reject zero amount conversion", async function () {
            await expect(
                bridge.connect(user1).convertToPrivate(0)
            ).to.be.revertedWithCustomError(bridge, "InvalidAmount");
        });
        
        it("Should handle multiple conversions", async function () {
            const amount1 = ethers.parseUnits("500", 6);
            const amount2 = ethers.parseUnits("300", 6);
            
            await bridge.connect(user1).convertToPrivate(amount1);
            await bridge.connect(user2).convertToPrivate(amount2);
            
            const expectedFee1 = (amount1 * DEFAULT_BRIDGE_FEE) / BASIS_POINTS;
            const expectedFee2 = (amount2 * DEFAULT_BRIDGE_FEE) / BASIS_POINTS;
            
            expect(await bridge.totalFeesCollected()).to.equal(expectedFee1 + expectedFee2);
            expect(await bridge.totalConvertedToPrivate()).to.equal(amount1 + amount2);
        });
    });
    
    describe("Convert to Public", function () {
        beforeEach(async function () {
            // Setup: Convert some tokens to private first
            const amount = ethers.parseUnits("5000", 6);
            await bridge.connect(user1).convertToPrivate(amount);
            
            // Bridge should now hold OmniCoin
            expect(await omniCoin.balanceOf(await bridge.getAddress())).to.be.gt(0);
        });
        
        it("Should convert PrivateOmniCoin back to OmniCoin with no fee", async function () {
            const amount = ethers.parseUnits("1000", 6);
            
            const omniBalanceBefore = await omniCoin.balanceOf(await user1.getAddress());
            const privateBalanceBefore = await privateOmniCoin.balanceOf(await user1.getAddress());
            
            await expect(bridge.connect(user1).convertToPublic(amount))
                .to.emit(bridge, "ConvertedToPublic")
                .withArgs(await user1.getAddress(), amount);
            
            const omniBalanceAfter = await omniCoin.balanceOf(await user1.getAddress());
            const privateBalanceAfter = await privateOmniCoin.balanceOf(await user1.getAddress());
            
            // Full amount should be returned (no fee)
            expect(omniBalanceAfter - omniBalanceBefore).to.equal(amount);
            expect(privateBalanceBefore - privateBalanceAfter).to.equal(amount);
            
            // Check statistics
            expect(await bridge.totalConvertedToPublic()).to.equal(amount);
        });
        
        it("Should reject conversion if bridge has insufficient balance", async function () {
            // Try to convert more than bridge holds
            const bridgeBalance = await omniCoin.balanceOf(await bridge.getAddress());
            const excessAmount = bridgeBalance + ethers.parseUnits("1", 6);
            
            // First mint private tokens to user (simulating a scenario)
            await privateOmniCoin.mint(await user1.getAddress(), excessAmount);
            
            await expect(
                bridge.connect(user1).convertToPublic(excessAmount)
            ).to.be.revertedWithCustomError(bridge, "InsufficientBalance");
        });
        
        it("Should reject zero amount conversion", async function () {
            await expect(
                bridge.connect(user1).convertToPublic(0)
            ).to.be.revertedWithCustomError(bridge, "InvalidAmount");
        });
    });
    
    describe("Fee Management", function () {
        it("Should update bridge fee", async function () {
            const newFee = 150n; // 1.5%
            
            await expect(bridge.connect(feeManager).setBridgeFee(newFee))
                .to.emit(bridge, "BridgeFeeUpdated")
                .withArgs(DEFAULT_BRIDGE_FEE, newFee);
            
            expect(await bridge.bridgeFee()).to.equal(newFee);
        });
        
        it("Should reject fee above maximum", async function () {
            const excessiveFee = MAX_BRIDGE_FEE + 1n;
            
            await expect(
                bridge.connect(feeManager).setBridgeFee(excessiveFee)
            ).to.be.revertedWithCustomError(bridge, "InvalidFee");
        });
        
        it("Should only allow fee manager to update fee", async function () {
            await expect(
                bridge.connect(user1).setBridgeFee(150)
            ).to.be.revertedWith(/AccessControl/);
        });
        
        it("Should withdraw collected fees", async function () {
            // Generate some fees
            const amount = ethers.parseUnits("1000", 6);
            await bridge.connect(user1).convertToPrivate(amount);
            
            const collectedFees = await bridge.totalFeesCollected();
            expect(collectedFees).to.be.gt(0);
            
            const treasuryBalanceBefore = await omniCoin.balanceOf(await treasury.getAddress());
            
            await expect(bridge.connect(feeManager).withdrawFees(
                await treasury.getAddress(),
                collectedFees
            ))
                .to.emit(bridge, "FeesWithdrawn")
                .withArgs(await treasury.getAddress(), collectedFees);
            
            const treasuryBalanceAfter = await omniCoin.balanceOf(await treasury.getAddress());
            expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(collectedFees);
            expect(await bridge.totalFeesCollected()).to.equal(0);
        });
        
        it("Should reject withdrawal of more than collected fees", async function () {
            const collectedFees = await bridge.totalFeesCollected();
            const excessAmount = collectedFees + ethers.parseUnits("1", 6);
            
            await expect(
                bridge.connect(feeManager).withdrawFees(
                    await treasury.getAddress(),
                    excessAmount
                )
            ).to.be.revertedWithCustomError(bridge, "InsufficientBalance");
        });
        
        it("Should reject withdrawal to zero address", async function () {
            await expect(
                bridge.connect(feeManager).withdrawFees(
                    ethers.ZeroAddress,
                    ethers.parseUnits("100", 6)
                )
            ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
        });
    });
    
    describe("Pausable", function () {
        it("Should pause bridge", async function () {
            await bridge.connect(pauser).pause();
            expect(await bridge.paused()).to.be.true;
            
            // Should reject conversions when paused
            await expect(
                bridge.connect(user1).convertToPrivate(ethers.parseUnits("100", 6))
            ).to.be.revertedWith("Pausable: paused");
            
            await expect(
                bridge.connect(user1).convertToPublic(ethers.parseUnits("100", 6))
            ).to.be.revertedWith("Pausable: paused");
        });
        
        it("Should unpause bridge", async function () {
            await bridge.connect(pauser).pause();
            await bridge.connect(pauser).unpause();
            expect(await bridge.paused()).to.be.false;
            
            // Should allow conversions after unpause
            await expect(
                bridge.connect(user1).convertToPrivate(ethers.parseUnits("100", 6))
            ).to.not.be.reverted;
        });
        
        it("Should only allow pauser role to pause/unpause", async function () {
            await expect(
                bridge.connect(user1).pause()
            ).to.be.revertedWith(/AccessControl/);
            
            await bridge.connect(pauser).pause();
            
            await expect(
                bridge.connect(user1).unpause()
            ).to.be.revertedWith(/AccessControl/);
        });
    });
    
    describe("Bridge Statistics", function () {
        it("Should track bridge statistics correctly", async function () {
            const amount1 = ethers.parseUnits("1000", 6);
            const amount2 = ethers.parseUnits("500", 6);
            
            // Convert to private
            await bridge.connect(user1).convertToPrivate(amount1);
            
            let stats = await bridge.getBridgeStats();
            expect(stats.publicBalance).to.equal(amount1);
            expect(stats.toPrivate).to.equal(amount1);
            expect(stats.toPublic).to.equal(0);
            
            // Convert back to public
            await bridge.connect(user1).convertToPublic(amount2);
            
            stats = await bridge.getBridgeStats();
            expect(stats.publicBalance).to.equal(amount1 - amount2);
            expect(stats.toPrivate).to.equal(amount1);
            expect(stats.toPublic).to.equal(amount2);
            
            // Check private token supply
            const expectedFee = (amount1 * DEFAULT_BRIDGE_FEE) / BASIS_POINTS;
            const expectedPrivateSupply = amount1 - expectedFee - amount2;
            expect(stats.privateSupply).to.equal(expectedPrivateSupply);
        });
    });
    
    describe("Integration Scenarios", function () {
        it("Should handle full conversion cycle", async function () {
            const initialAmount = ethers.parseUnits("1000", 6);
            
            // Step 1: Convert to private
            await bridge.connect(user1).convertToPrivate(initialAmount);
            
            const fee = (initialAmount * DEFAULT_BRIDGE_FEE) / BASIS_POINTS;
            const privateBalance = await privateOmniCoin.balanceOf(await user1.getAddress());
            expect(privateBalance).to.equal(initialAmount - fee);
            
            // Step 2: Convert back to public
            await bridge.connect(user1).convertToPublic(privateBalance);
            
            // User should have less than initial due to fee
            const finalBalance = await omniCoin.balanceOf(await user1.getAddress());
            expect(finalBalance).to.equal(ethers.parseUnits("10000", 6) - fee);
        });
        
        it("Should maintain 1:1 backing (accounting for fees)", async function () {
            // Multiple users convert
            await bridge.connect(user1).convertToPrivate(ethers.parseUnits("1000", 6));
            await bridge.connect(user2).convertToPrivate(ethers.parseUnits("500", 6));
            
            const stats = await bridge.getBridgeStats();
            
            // Bridge balance should equal: total converted - fees collected
            const expectedBridgeBalance = stats.toPrivate - stats.feesCollected;
            expect(stats.publicBalance).to.equal(expectedBridgeBalance);
            
            // Private supply should equal: total converted - fees - amount converted back
            const expectedPrivateSupply = stats.toPrivate - stats.feesCollected - stats.toPublic;
            expect(stats.privateSupply).to.equal(expectedPrivateSupply);
        });
    });
});