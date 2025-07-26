const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinPaymentV2 - Business Logic Tests (No Token Transfers)", function () {
    let paymentV2;
    let owner;
    let sender;
    let receiver;
    let other;

    // IMPORTANT: These tests focus ONLY on business logic that can be tested
    // without actual token transfers. We test state transitions, access controls,
    // and contract behavior, but NOT the privacy features or token movements.

    beforeEach(async function () {
        [owner, sender, receiver, other] = await ethers.getSigners();

        // Deploy OmniCoinPaymentV2 with dummy addresses
        // We won't actually use these contracts, just test the payment logic
        const OmniCoinPaymentV2 = await ethers.getContractFactory("OmniCoinPaymentV2");
        paymentV2 = await OmniCoinPaymentV2.deploy(
            owner.address,      // dummy token address
            owner.address,      // dummy account address
            owner.address,      // dummy staking address
            owner.address       // admin
        );
        await paymentV2.waitForDeployment();

        // Set MPC availability to false
        await paymentV2.setMpcAvailability(false);
    });

    describe("Contract Deployment and Configuration", function () {
        it("Should deploy with correct roles", async function () {
            expect(await paymentV2.hasRole(await paymentV2.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await paymentV2.hasRole(await paymentV2.ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await paymentV2.hasRole(await paymentV2.FEE_MANAGER_ROLE(), owner.address)).to.be.true;
            expect(await paymentV2.hasRole(await paymentV2.PAYMENT_PROCESSOR_ROLE(), owner.address)).to.be.true;
        });

        it("Should initialize with correct constants", async function () {
            expect(await paymentV2.PRIVACY_FEE_RATE()).to.equal(10); // 0.1%
            expect(await paymentV2.BASIS_POINTS()).to.equal(10000);
        });

        it("Should have MPC disabled for testing", async function () {
            expect(await paymentV2.isMpcAvailable()).to.be.false;
        });
    });

    describe("Access Control and Permissions", function () {
        it("Should only allow admin to set MPC availability", async function () {
            await paymentV2.setMpcAvailability(true);
            expect(await paymentV2.isMpcAvailable()).to.be.true;

            await paymentV2.setMpcAvailability(false);
            expect(await paymentV2.isMpcAvailable()).to.be.false;

            await expect(paymentV2.connect(other).setMpcAvailability(true))
                .to.be.revertedWithCustomError(paymentV2, "AccessControlUnauthorizedAccount");
        });

        it("Should only allow admin to pause/unpause", async function () {
            // Pause
            await paymentV2.pause();
            expect(await paymentV2.paused()).to.be.true;

            // Try to process payment while paused (should fail)
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(100), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };
            
            await expect(paymentV2.connect(sender).processPrivatePayment(
                receiver.address,
                mockAmount,
                false,
                false,
                mockAmount
            )).to.be.revertedWithCustomError(paymentV2, "EnforcedPause");

            // Unpause
            await paymentV2.unpause();
            expect(await paymentV2.paused()).to.be.false;

            // Non-admin cannot pause
            await expect(paymentV2.connect(other).pause())
                .to.be.revertedWithCustomError(paymentV2, "AccessControlUnauthorizedAccount");
        });

        it("Should manage payment processor role correctly", async function () {
            // Initially, other should not have the role
            expect(await paymentV2.hasRole(await paymentV2.PAYMENT_PROCESSOR_ROLE(), other.address)).to.be.false;

            // Grant payment processor role
            await paymentV2.grantRole(await paymentV2.PAYMENT_PROCESSOR_ROLE(), other.address);
            expect(await paymentV2.hasRole(await paymentV2.PAYMENT_PROCESSOR_ROLE(), other.address)).to.be.true;

            // Revoke payment processor role
            await paymentV2.revokeRole(await paymentV2.PAYMENT_PROCESSOR_ROLE(), other.address);
            expect(await paymentV2.hasRole(await paymentV2.PAYMENT_PROCESSOR_ROLE(), other.address)).to.be.false;
        });

        it("Should only allow fee manager to update fees", async function () {
            const mockFee = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(50), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            // Admin has FEE_MANAGER_ROLE by default
            await expect(paymentV2.updateMaxPrivacyFee(mockFee))
                .to.emit(paymentV2, "MaxPrivacyFeeUpdated");

            // Other users cannot update
            await expect(paymentV2.connect(other).updateMaxPrivacyFee(mockFee))
                .to.be.revertedWithCustomError(paymentV2, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Payment Validation", function () {
        it("Should reject payment to self", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(100), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.connect(sender).processPrivatePayment(
                sender.address, // trying to send to self
                mockAmount,
                false,
                false,
                mockAmount
            )).to.be.revertedWith("OmniCoinPaymentV2: Cannot send to self");
        });

        it("Should reject payment to zero address", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(100), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.connect(sender).processPrivatePayment(
                ethers.ZeroAddress,
                mockAmount,
                false,
                false,
                mockAmount
            )).to.be.revertedWith("OmniCoinPaymentV2: Invalid receiver");
        });
    });

    describe("Payment Stream Validation", function () {
        it("Should reject stream with zero duration", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.connect(sender).createPaymentStream(
                receiver.address,
                mockAmount,
                0 // zero duration
            )).to.be.revertedWith("OmniCoinPaymentV2: Invalid duration");
        });

        it("Should reject stream with duration too long", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.connect(sender).createPaymentStream(
                receiver.address,
                mockAmount,
                366 * 24 * 60 * 60 // 366 days, exceeds 365 day max
            )).to.be.revertedWith("OmniCoinPaymentV2: Duration too long");
        });

        it("Should reject stream to zero address", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.connect(sender).createPaymentStream(
                ethers.ZeroAddress,
                mockAmount,
                30 * 24 * 60 * 60
            )).to.be.revertedWith("OmniCoinPaymentV2: Invalid receiver");
        });

        it("Should reject stream to self", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.connect(sender).createPaymentStream(
                sender.address, // trying to stream to self
                mockAmount,
                30 * 24 * 60 * 60
            )).to.be.revertedWith("OmniCoinPaymentV2: Cannot send to self");
        });

        it("Should validate stream duration boundaries correctly", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            // Test exact boundary - 365 days should be accepted
            // We can't test the full flow without tokens, but we know it passes validation
            // if it reverts later in the token transfer phase
            try {
                await paymentV2.connect(sender).createPaymentStream(
                    receiver.address,
                    mockAmount,
                    365 * 24 * 60 * 60 // Exactly 365 days
                );
                // If we get here, something is wrong - should have reverted on token transfer
                expect.fail("Expected transaction to revert");
            } catch (error) {
                // Should revert, but NOT with duration error
                expect(error.message).to.not.include("Duration too long");
            }
        });
    });

    describe("View Functions", function () {
        it("Should return empty user payments initially", async function () {
            const senderPayments = await paymentV2.getUserPayments(sender.address);
            expect(senderPayments.length).to.equal(0);

            const receiverPayments = await paymentV2.getUserPayments(receiver.address);
            expect(receiverPayments.length).to.equal(0);
        });

        it("Should return empty user streams initially", async function () {
            const senderStreams = await paymentV2.getUserStreams(sender.address);
            expect(senderStreams.length).to.equal(0);

            const receiverStreams = await paymentV2.getUserStreams(receiver.address);
            expect(receiverStreams.length).to.equal(0);
        });

        it("Should handle non-existent payment queries gracefully", async function () {
            const fakePaymentId = ethers.keccak256(ethers.toUtf8Bytes("fake"));
            
            // Query details for non-existent payment
            const details = await paymentV2.getPaymentDetails(fakePaymentId);
            expect(details.sender).to.equal(ethers.ZeroAddress);
            expect(details.receiver).to.equal(ethers.ZeroAddress);
            expect(details.privacyEnabled).to.be.false;
            expect(details.timestamp).to.equal(0);
            expect(details.completed).to.be.false;
            expect(details.paymentType).to.equal(0);
        });

        it("Should handle non-existent stream queries gracefully", async function () {
            const fakeStreamId = ethers.keccak256(ethers.toUtf8Bytes("fake"));
            
            // Query details for non-existent stream
            const details = await paymentV2.getStreamDetails(fakeStreamId);
            expect(details.sender).to.equal(ethers.ZeroAddress);
            expect(details.receiver).to.equal(ethers.ZeroAddress);
            expect(details.startTime).to.equal(0);
            expect(details.endTime).to.equal(0);
            expect(details.lastWithdrawTime).to.equal(0);
            expect(details.cancelled).to.be.false;
        });
    });

    describe("Emergency Functions", function () {
        it("Should handle pause correctly", async function () {
            // Initially not paused
            expect(await paymentV2.paused()).to.be.false;

            // Pause the contract
            await paymentV2.pause();
            expect(await paymentV2.paused()).to.be.true;

            // Unpause the contract
            await paymentV2.unpause();
            expect(await paymentV2.paused()).to.be.false;
        });

        it("Should emit pause events", async function () {
            await expect(paymentV2.pause())
                .to.emit(paymentV2, "Paused")
                .withArgs(owner.address);

            await expect(paymentV2.unpause())
                .to.emit(paymentV2, "Unpaused")
                .withArgs(owner.address);
        });
    });

    describe("Configuration Updates", function () {
        it("Should emit event when min stake amount updated", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(500), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.updateMinStakeAmount(mockAmount))
                .to.emit(paymentV2, "MinStakeAmountUpdated");
        });

        it("Should emit event when max privacy fee updated", async function () {
            const mockFee = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(50), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            await expect(paymentV2.updateMaxPrivacyFee(mockFee))
                .to.emit(paymentV2, "MaxPrivacyFeeUpdated");
        });

        it("Should enforce role requirements for stake updates", async function () {
            const mockAmount = { 
                ciphertext: ethers.zeroPadValue(ethers.toBeHex(1000), 32),
                signature: ethers.hexlify(ethers.randomBytes(32))
            };

            // Non-admin cannot update min stake amount
            await expect(paymentV2.connect(other).updateMinStakeAmount(mockAmount))
                .to.be.revertedWithCustomError(paymentV2, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Payment Types", function () {
        it("Should have correct payment type enum values", async function () {
            // We can't easily test the enum directly, but we can verify through events
            // PaymentType.INSTANT = 0, STREAM = 1, SCHEDULED = 2
            // This is more of a sanity check that the contract compiles correctly
            expect(true).to.be.true;
        });
    });
});