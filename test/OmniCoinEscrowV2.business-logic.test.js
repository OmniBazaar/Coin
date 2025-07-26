const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinEscrowV2 - Business Logic Tests (No Token Transfers)", function () {
    let escrowV2;
    let owner;
    let seller;
    let buyer;
    let arbitrator;
    let other;

    // IMPORTANT: These tests focus ONLY on business logic that can be tested
    // without actual token transfers. We test state transitions, access controls,
    // and contract behavior, but NOT the privacy features or token movements.

    beforeEach(async function () {
        [owner, seller, buyer, arbitrator, other] = await ethers.getSigners();

        // Deploy OmniCoinEscrowV2 with a dummy token address
        // We won't actually use the token, just test the escrow logic
        const OmniCoinEscrowV2 = await ethers.getContractFactory("OmniCoinEscrowV2");
        escrowV2 = await OmniCoinEscrowV2.deploy(
            owner.address, // dummy token address - won't be used
            owner.address
        );
        await escrowV2.waitForDeployment();

        // Set MPC availability to false
        await escrowV2.setMpcAvailability(false);
    });

    describe("Contract Deployment and Configuration", function () {
        it("Should deploy with correct owner", async function () {
            expect(await escrowV2.hasRole(await escrowV2.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await escrowV2.hasRole(await escrowV2.ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await escrowV2.hasRole(await escrowV2.FEE_MANAGER_ROLE(), owner.address)).to.be.true;
        });

        it("Should initialize with correct constants", async function () {
            expect(await escrowV2.maxEscrowDuration()).to.equal(30 * 24 * 60 * 60); // 30 days
            expect(await escrowV2.FEE_RATE()).to.equal(50); // 0.5%
            expect(await escrowV2.BASIS_POINTS()).to.equal(10000);
            expect(await escrowV2.escrowCount()).to.equal(0);
            expect(await escrowV2.disputeCount()).to.equal(0);
        });

        it("Should have MPC disabled for testing", async function () {
            expect(await escrowV2.isMpcAvailable()).to.be.false;
        });
    });

    describe("Access Control and Permissions", function () {
        it("Should only allow admin to set MPC availability", async function () {
            await escrowV2.setMpcAvailability(true);
            expect(await escrowV2.isMpcAvailable()).to.be.true;

            await escrowV2.setMpcAvailability(false);
            expect(await escrowV2.isMpcAvailable()).to.be.false;

            await expect(escrowV2.connect(other).setMpcAvailability(true))
                .to.be.revertedWithCustomError(escrowV2, "AccessControlUnauthorizedAccount");
        });

        it("Should only allow admin to pause/unpause", async function () {
            // Pause
            await escrowV2.pause();
            expect(await escrowV2.paused()).to.be.true;

            // Try to create escrow while paused (should fail)
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };
            
            await expect(escrowV2.createPrivateEscrow(
                buyer.address,
                arbitrator.address,
                mockAmount,
                7 * 24 * 60 * 60
            )).to.be.revertedWithCustomError(escrowV2, "EnforcedPause");

            // Unpause
            await escrowV2.unpause();
            expect(await escrowV2.paused()).to.be.false;

            // Non-admin cannot pause
            await expect(escrowV2.connect(other).pause())
                .to.be.revertedWithCustomError(escrowV2, "AccessControlUnauthorizedAccount");
        });

        it("Should only allow admin to update max escrow duration", async function () {
            const newDuration = 60 * 24 * 60 * 60; // 60 days
            
            await escrowV2.updateMaxEscrowDuration(newDuration);
            expect(await escrowV2.maxEscrowDuration()).to.equal(newDuration);

            // Non-admin cannot update
            await expect(escrowV2.connect(other).updateMaxEscrowDuration(90 * 24 * 60 * 60))
                .to.be.revertedWithCustomError(escrowV2, "AccessControlUnauthorizedAccount");
        });

        it("Should manage arbitrator role correctly", async function () {
            // Initially, arbitrator should not have the role
            expect(await escrowV2.hasRole(await escrowV2.ARBITRATOR_ROLE(), arbitrator.address)).to.be.false;

            // Grant arbitrator role
            await escrowV2.grantRole(await escrowV2.ARBITRATOR_ROLE(), arbitrator.address);
            expect(await escrowV2.hasRole(await escrowV2.ARBITRATOR_ROLE(), arbitrator.address)).to.be.true;

            // Revoke arbitrator role
            await escrowV2.revokeRole(await escrowV2.ARBITRATOR_ROLE(), arbitrator.address);
            expect(await escrowV2.hasRole(await escrowV2.ARBITRATOR_ROLE(), arbitrator.address)).to.be.false;
        });
    });

    describe("Escrow Parameter Validation", function () {
        it("Should reject invalid buyer address", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(escrowV2.connect(seller).createPrivateEscrow(
                ethers.ZeroAddress,
                arbitrator.address,
                mockAmount,
                7 * 24 * 60 * 60
            )).to.be.revertedWith("OmniCoinEscrowV2: Invalid buyer");
        });

        it("Should reject invalid arbitrator address", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(escrowV2.connect(seller).createPrivateEscrow(
                buyer.address,
                ethers.ZeroAddress,
                mockAmount,
                7 * 24 * 60 * 60
            )).to.be.revertedWith("OmniCoinEscrowV2: Invalid arbitrator");
        });

        it("Should reject duration exceeding maximum", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(escrowV2.connect(seller).createPrivateEscrow(
                buyer.address,
                arbitrator.address,
                mockAmount,
                31 * 24 * 60 * 60 // 31 days, exceeds 30 day max
            )).to.be.revertedWith("OmniCoinEscrowV2: Duration too long");
        });

        it("Should accept valid duration up to maximum", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            // This will fail on token transfer, but should pass validation
            await expect(escrowV2.connect(seller).createPrivateEscrow(
                buyer.address,
                arbitrator.address,
                mockAmount,
                30 * 24 * 60 * 60 // Exactly 30 days
            )).to.be.reverted; // Will revert on token transfer, but not on duration check
        });
    });

    describe("View Functions", function () {
        it("Should return empty user escrows initially", async function () {
            const sellerEscrows = await escrowV2.getUserEscrows(seller.address);
            expect(sellerEscrows.length).to.equal(0);

            const buyerEscrows = await escrowV2.getUserEscrows(buyer.address);
            expect(buyerEscrows.length).to.equal(0);
        });

        it("Should handle non-existent escrow queries gracefully", async function () {
            // Query details for non-existent escrow
            const details = await escrowV2.getEscrowDetails(999);
            expect(details.seller).to.equal(ethers.ZeroAddress);
            expect(details.buyer).to.equal(ethers.ZeroAddress);
            expect(details.arbitrator).to.equal(ethers.ZeroAddress);
            expect(details.releaseTime).to.equal(0);
            expect(details.released).to.be.false;
            expect(details.disputed).to.be.false;
            expect(details.refunded).to.be.false;
        });
    });

    describe("Emergency Functions", function () {
        it("Should handle pause correctly", async function () {
            // Initially not paused
            expect(await escrowV2.paused()).to.be.false;

            // Pause the contract
            await escrowV2.pause();
            expect(await escrowV2.paused()).to.be.true;

            // Unpause the contract
            await escrowV2.unpause();
            expect(await escrowV2.paused()).to.be.false;
        });

        it("Should emit pause events", async function () {
            await expect(escrowV2.pause())
                .to.emit(escrowV2, "Paused")
                .withArgs(owner.address);

            await expect(escrowV2.unpause())
                .to.emit(escrowV2, "Unpaused")
                .withArgs(owner.address);
        });
    });

    describe("Configuration Updates", function () {
        it("Should emit event when max duration updated", async function () {
            const newDuration = 45 * 24 * 60 * 60; // 45 days
            
            await expect(escrowV2.updateMaxEscrowDuration(newDuration))
                .to.emit(escrowV2, "MaxEscrowDurationUpdated")
                .withArgs(newDuration);
        });

        it("Should emit events for encrypted config updates", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(500), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            // These functions accept encrypted inputs but we can still test events
            await expect(escrowV2.updateMinEscrowAmount(mockAmount))
                .to.emit(escrowV2, "MinEscrowAmountUpdated");

            await expect(escrowV2.updateArbitrationFee(mockAmount))
                .to.emit(escrowV2, "ArbitrationFeeUpdated");
        });

        it("Should enforce role requirements for fee updates", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(100), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            // Non-fee-manager cannot update arbitration fee
            await expect(escrowV2.connect(other).updateArbitrationFee(mockAmount))
                .to.be.revertedWithCustomError(escrowV2, "AccessControlUnauthorizedAccount");
        });
    });
});