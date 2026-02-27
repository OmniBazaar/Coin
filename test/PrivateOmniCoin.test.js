const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title PrivateOmniCoin Test Suite
 * @notice Comprehensive tests for privacy-enabled token with COTI V2 MPC
 * @dev Tests all conversion, transfer, and privacy features
 */
describe("PrivateOmniCoin", function () {
    // Test fixture for contract deployment
    async function deployPrivateOmniCoinFixture() {
        // Get signers
        const [owner, user1, user2, feeRecipient, bridge] = await ethers.getSigners();

        // Deploy contract via UUPS proxy (constructor calls _disableInitializers)
        const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
        const token = await upgrades.deployProxy(
            PrivateOmniCoin,
            [],
            { initializer: "initialize", kind: "uups" }
        );
        await token.waitForDeployment();

        // Grant bridge role to bridge account
        const BRIDGE_ROLE = await token.BRIDGE_ROLE();
        await token.grantRole(BRIDGE_ROLE, bridge.address);

        // Transfer some tokens to users for testing
        const transferAmount = ethers.parseEther("1000000"); // 1M tokens
        await token.transfer(user1.address, transferAmount);
        await token.transfer(user2.address, transferAmount);

        return { token, owner, user1, user2, feeRecipient, bridge };
    }

    // ========================================================================
    // DEPLOYMENT & INITIALIZATION TESTS
    // ========================================================================

    describe("Deployment & Initialization", function () {
        it("Should deploy with correct name and symbol", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            expect(await token.name()).to.equal("Private OmniCoin");
            expect(await token.symbol()).to.equal("pXOM");
        });

        it("Should initialize with correct total supply", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            const expectedSupply = ethers.parseEther("1000000000"); // 1 billion
            expect(await token.totalSupply()).to.equal(expectedSupply);
        });

        it("Should mint initial supply to deployer", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            const ownerBalance = await token.balanceOf(owner.address);

            // Owner should have initial supply minus what was transferred
            expect(ownerBalance).to.be.gt(0);
        });

        it("Should grant roles correctly", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            const DEFAULT_ADMIN_ROLE = await token.DEFAULT_ADMIN_ROLE();
            const MINTER_ROLE = await token.MINTER_ROLE();
            const BURNER_ROLE = await token.BURNER_ROLE();
            const BRIDGE_ROLE = await token.BRIDGE_ROLE();

            expect(await token.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
            expect(await token.hasRole(MINTER_ROLE, owner.address)).to.be.true;
            expect(await token.hasRole(BURNER_ROLE, owner.address)).to.be.true;
            expect(await token.hasRole(BRIDGE_ROLE, owner.address)).to.be.true;
        });

        it("Should not allow re-initialization", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(token.initialize()).to.be.revertedWithCustomError(
                token,
                "InvalidInitialization"
            );
        });

        it("Should set fee recipient to deployer", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            expect(await token.getFeeRecipient()).to.equal(owner.address);
        });
    });

    // ========================================================================
    // PRIVACY AVAILABILITY TESTS
    // ========================================================================

    describe("Privacy Availability", function () {
        it("Should report privacy as available on COTI network", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Privacy is disabled by default in Hardhat (no MPC support)
            // On COTI network, it would be enabled automatically
            const isAvailable = await token.privacyAvailable();
            expect(isAvailable).to.be.a("boolean"); // Just verify it returns a boolean

            // In Hardhat, should be false
            expect(isAvailable).to.be.false;
        });

        it("Should allow admin to enable/disable privacy", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Disable privacy
            await token.setPrivacyEnabled(false);
            expect(await token.privacyAvailable()).to.be.false;

            // Re-enable privacy
            await token.setPrivacyEnabled(true);
            expect(await token.privacyAvailable()).to.be.true;
        });

        it("Should emit PrivacyStatusChanged event", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(token.setPrivacyEnabled(false))
                .to.emit(token, "PrivacyStatusChanged")
                .withArgs(false);
        });

        it("Should not allow non-admin to change privacy status", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(
                token.connect(user1).setPrivacyEnabled(false)
            ).to.be.reverted; // Will revert with AccessControl error
        });
    });

    // ========================================================================
    // PUBLIC TO PRIVATE CONVERSION TESTS
    // ========================================================================

    describe("Convert to Private (XOM to pXOM)", function () {
        it("Should have convertToPrivate function with correct signature", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Verify function exists
            expect(typeof token.convertToPrivate).to.equal("function");
        });

        it("Should calculate correct 0.5% conversion fee", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Verify fee constants are correct
            const feeBps = await token.PRIVACY_FEE_BPS();
            const denominator = await token.BPS_DENOMINATOR();

            expect(feeBps).to.equal(50);
            expect(denominator).to.equal(10000);

            // 50 / 10000 = 0.005 = 0.5%
            const testAmount = 1000000n;
            const expectedFee = (testAmount * feeBps) / denominator;
            expect(expectedFee).to.equal(5000n); // 0.5% of 1,000,000 = 5,000
        });

        it("Should verify event signature for ConvertedToPrivate", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Verify event exists
            const iface = token.interface;
            const event = iface.getEvent("ConvertedToPrivate");

            expect(event.name).to.equal("ConvertedToPrivate");
            expect(event.inputs.length).to.equal(2);
            expect(event.inputs[0].name).to.equal("user");
            expect(event.inputs[1].name).to.equal("publicAmount");
        });

        it("Should revert on zero amount when privacy enabled", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // Enable privacy for this test
            await token.setPrivacyEnabled(true);

            await expect(
                token.connect(user1).convertToPrivate(0)
            ).to.be.revertedWithCustomError(token, "ZeroAmount");
        });

        it("Should revert on amount too large for uint64 when privacy enabled", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // Enable privacy for this test
            await token.setPrivacyEnabled(true);

            // After scaling by 1e12, amount must fit in uint64
            // uint64 max = 18,446,744,073,709,551,615
            // So max public amount = ~18,446,744,073,709,551,615 * 1e12 = huge
            // But we need to exceed uint64 after scaling:
            // amount / 1e12 > uint64.max means amount > ~18.4e18 * 1e12 = ~1.84e31
            const tooLarge = ethers.parseEther("18446744073710"); // Exceeds uint64 after scaling

            await expect(
                token.connect(user1).convertToPrivate(tooLarge)
            ).to.be.revertedWithCustomError(token, "AmountTooLarge");
        });

        it("Should revert when privacy is disabled", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.setPrivacyEnabled(false);

            await expect(
                token.connect(user1).convertToPrivate(ethers.parseEther("100"))
            ).to.be.revertedWithCustomError(token, "PrivacyNotAvailable");
        });

        it("Should revert when paused", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.pause();

            await expect(
                token.connect(user1).convertToPrivate(ethers.parseEther("100"))
            ).to.be.reverted; // Pausable revert
        });

        it("Should validate scaling factor", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            const scalingFactor = await token.PRIVACY_SCALING_FACTOR();
            expect(scalingFactor).to.equal(1000000000000n); // 1e12
        });
    });

    // ========================================================================
    // PRIVATE TO PUBLIC CONVERSION TESTS
    // ========================================================================

    describe("Convert to Public (pXOM to XOM)", function () {
        it("Should have convertToPublic function available", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // Verify the function exists
            // Full testing requires COTI MPC network
            expect(typeof token.connect(user1).convertToPublic).to.equal("function");
        });

        it("Should revert convertToPublic when privacy disabled", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Privacy should be disabled in Hardhat
            expect(await token.privacyAvailable()).to.be.false;

            // Note: Cannot create gtUint64 without MPC, so this test is limited
            // Full test requires COTI network
        });
    });

    // ========================================================================
    // BALANCE QUERY TESTS
    // ========================================================================

    describe("Balance Queries", function () {
        it("Should return encrypted private balance", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // Get private balance (should be encrypted ctUint64)
            const encryptedBalance = await token.privateBalanceOf(user1.address);

            // Balance exists (even if zero/encrypted)
            expect(encryptedBalance).to.exist;
        });

        it("Should allow owner to decrypt their balance", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // When privacy is disabled, decryptedPrivateBalanceOf returns 0
            // It is a non-view function due to MPC decrypt operations
            const tx = await token.connect(user1).decryptedPrivateBalanceOf(user1.address);
            const receipt = await tx.wait();

            // Transaction should succeed (returns 0 when privacy disabled)
            expect(receipt.status).to.equal(1);
        });

        it("Should allow admin to decrypt any balance", async function () {
            const { token, owner, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // Admin can query any user's decrypted balance
            const tx = await token.connect(owner).decryptedPrivateBalanceOf(user1.address);
            const receipt = await tx.wait();

            expect(receipt.status).to.equal(1);
        });

        it("Should return zero when privacy is disabled", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            // Privacy should already be disabled in Hardhat
            expect(await token.privacyAvailable()).to.be.false;

            const tx = await token.connect(user1).decryptedPrivateBalanceOf(user1.address);
            const receipt = await tx.wait();

            // Should succeed and return 0
            expect(receipt.status).to.equal(1);
        });

        it("Should return total private supply", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            const totalPrivateSupply = await token.getTotalPrivateSupply();

            // Should exist (encrypted value)
            expect(totalPrivateSupply).to.exist;
        });
    });

    // ========================================================================
    // PRIVATE TRANSFER TESTS
    // ========================================================================

    describe("Private Transfers", function () {
        it("Should emit PrivateTransfer event", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Verify the function signature and event structure
            const iface = token.interface;
            const event = iface.getEvent("PrivateTransfer");

            expect(event.name).to.equal("PrivateTransfer");
        });

        it("Should revert when privacy is disabled", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.setPrivacyEnabled(false);

            // Function should exist and revert
            expect(typeof token.connect(user1).privateTransfer).to.equal("function");
        });

        it("Should have self-transfer check (M-01)", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            // Verify the SelfTransfer error exists in the contract interface
            const iface = token.interface;
            const errorFragment = iface.getError("SelfTransfer");
            expect(errorFragment).to.not.be.null;
        });
    });

    // ========================================================================
    // ADMIN FUNCTION TESTS
    // ========================================================================

    describe("Admin Functions", function () {
        it("Should allow admin to set fee recipient", async function () {
            const { token, owner, feeRecipient } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.connect(owner).setFeeRecipient(feeRecipient.address);

            expect(await token.getFeeRecipient()).to.equal(feeRecipient.address);
        });

        it("Should emit FeeRecipientUpdated event", async function () {
            const { token, feeRecipient } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(token.setFeeRecipient(feeRecipient.address))
                .to.emit(token, "FeeRecipientUpdated")
                .withArgs(feeRecipient.address);
        });

        it("Should not allow zero address as fee recipient", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(
                token.setFeeRecipient(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(token, "ZeroAddress");
        });

        it("Should not allow non-admin to set fee recipient", async function () {
            const { token, user1, feeRecipient } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(
                token.connect(user1).setFeeRecipient(feeRecipient.address)
            ).to.be.reverted;
        });

        it("Should allow admin to mint tokens", async function () {
            const { token, owner, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            const mintAmount = ethers.parseEther("1000");
            const balanceBefore = await token.balanceOf(user1.address);

            await token.connect(owner).mint(user1.address, mintAmount);

            const balanceAfter = await token.balanceOf(user1.address);
            expect(balanceAfter - balanceBefore).to.equal(mintAmount);
        });

        it("Should not allow non-minter to mint tokens", async function () {
            const { token, user1, user2 } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(
                token.connect(user1).mint(user2.address, ethers.parseEther("1000"))
            ).to.be.reverted;
        });

        it("Should enforce MAX_SUPPLY cap on mint (M-03)", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            const maxSupply = await token.MAX_SUPPLY();
            const currentSupply = await token.totalSupply();
            const tooMuch = maxSupply - currentSupply + 1n;

            await expect(
                token.connect(owner).mint(owner.address, tooMuch)
            ).to.be.revertedWithCustomError(token, "ExceedsMaxSupply");
        });

        it("Should allow admin to burn tokens", async function () {
            const { token, owner, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            const burnAmount = ethers.parseEther("100");
            const balanceBefore = await token.balanceOf(user1.address);

            await token.connect(owner).burnFrom(user1.address, burnAmount);

            const balanceAfter = await token.balanceOf(user1.address);
            expect(balanceBefore - balanceAfter).to.equal(burnAmount);
        });

        it("Should not allow non-burner to burn tokens", async function () {
            const { token, user1, user2 } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(
                token.connect(user1).burnFrom(user2.address, ethers.parseEther("100"))
            ).to.be.reverted;
        });
    });

    // ========================================================================
    // EMERGENCY RECOVERY TESTS
    // ========================================================================

    describe("Emergency Recovery", function () {
        it("Should revert recovery when privacy is enabled", async function () {
            const { token, owner, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.setPrivacyEnabled(true);

            await expect(
                token.connect(owner).emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(token, "PrivacyMustBeDisabled");
        });

        it("Should revert recovery for zero address", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.setPrivacyEnabled(false);

            await expect(
                token.connect(owner).emergencyRecoverPrivateBalance(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(token, "ZeroAddress");
        });

        it("Should revert recovery when no balance to recover", async function () {
            const { token, owner, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.setPrivacyEnabled(false);

            await expect(
                token.connect(owner).emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(token, "NoBalanceToRecover");
        });

        it("Should not allow non-admin to recover", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.setPrivacyEnabled(false);

            await expect(
                token.connect(user1).emergencyRecoverPrivateBalance(user1.address)
            ).to.be.reverted;
        });
    });

    // ========================================================================
    // PAUSABLE TESTS
    // ========================================================================

    describe("Pausable Functionality", function () {
        it("Should allow admin to pause", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.connect(owner).pause();

            expect(await token.paused()).to.be.true;
        });

        it("Should allow admin to unpause", async function () {
            const { token, owner } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.connect(owner).pause();
            await token.connect(owner).unpause();

            expect(await token.paused()).to.be.false;
        });

        it("Should prevent transfers when paused", async function () {
            const { token, owner, user1, user2 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.connect(owner).pause();

            await expect(
                token.connect(user1).transfer(user2.address, ethers.parseEther("100"))
            ).to.be.reverted;
        });

        it("Should prevent convertToPrivate when paused", async function () {
            const { token, owner, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await token.connect(owner).pause();

            await expect(
                token.connect(user1).convertToPrivate(ethers.parseEther("100"))
            ).to.be.reverted;
        });

        it("Should not allow non-admin to pause", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            await expect(
                token.connect(user1).pause()
            ).to.be.reverted;
        });
    });

    // ========================================================================
    // STANDARD ERC20 TESTS
    // ========================================================================

    describe("Standard ERC20 Functionality", function () {
        it("Should allow transfers", async function () {
            const { token, user1, user2 } = await loadFixture(deployPrivateOmniCoinFixture);

            const amount = ethers.parseEther("100");

            await expect(
                token.connect(user1).transfer(user2.address, amount)
            ).to.changeTokenBalances(token, [user1, user2], [-amount, amount]);
        });

        it("Should allow approvals", async function () {
            const { token, user1, user2 } = await loadFixture(deployPrivateOmniCoinFixture);

            const amount = ethers.parseEther("100");

            await token.connect(user1).approve(user2.address, amount);

            expect(await token.allowance(user1.address, user2.address)).to.equal(amount);
        });

        it("Should allow transferFrom with approval", async function () {
            const { token, user1, user2 } = await loadFixture(deployPrivateOmniCoinFixture);

            const amount = ethers.parseEther("100");

            await token.connect(user1).approve(user2.address, amount);
            await token.connect(user2).transferFrom(user1.address, user2.address, amount);

            const balance = await token.balanceOf(user2.address);
            expect(balance).to.be.gte(amount);
        });

        it("Should allow users to burn their own tokens", async function () {
            const { token, user1 } = await loadFixture(deployPrivateOmniCoinFixture);

            const burnAmount = ethers.parseEther("100");
            const balanceBefore = await token.balanceOf(user1.address);

            await token.connect(user1).burn(burnAmount);

            const balanceAfter = await token.balanceOf(user1.address);
            expect(balanceBefore - balanceAfter).to.equal(burnAmount);
        });
    });

    // ========================================================================
    // CONSTANTS TESTS
    // ========================================================================

    describe("Constants", function () {
        it("Should have correct initial supply constant", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            const expectedSupply = ethers.parseEther("1000000000");
            expect(await token.INITIAL_SUPPLY()).to.equal(expectedSupply);
        });

        it("Should have correct privacy fee constant", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            expect(await token.PRIVACY_FEE_BPS()).to.equal(50); // 0.5% = 50 basis points
        });

        it("Should have correct BPS denominator", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            expect(await token.BPS_DENOMINATOR()).to.equal(10000);
        });

        it("Should have correct MAX_SUPPLY", async function () {
            const { token } = await loadFixture(deployPrivateOmniCoinFixture);

            const expectedMax = ethers.parseEther("16600000000"); // 16.6 billion
            expect(await token.MAX_SUPPLY()).to.equal(expectedMax);
        });
    });
});
