const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Dual Token Integration Tests", function () {
    let owner, user1, user2, treasury, validator;
    let registry, omniCoin, privateOmniCoin, feeManager, bridge;

    // Constants - updated for ethers v6
    const INITIAL_SUPPLY = ethers.parseUnits("100000000", 6); // 100M tokens
    const TEST_AMOUNT = ethers.parseUnits("1000", 6);
    const BRIDGE_FEE = 100n; // 1%

    beforeEach(async function () {
        [owner, user1, user2, treasury, validator] = await ethers.getSigners();

        // 1. Deploy Registry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(owner.address);
        await registry.waitForDeployment();

        // 2. Deploy OmniCoin (public token)
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();

        // 3. Deploy PrivateOmniCoin
        const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
        privateOmniCoin = await PrivateOmniCoin.deploy(await registry.getAddress());
        await privateOmniCoin.waitForDeployment();

        // 4. Deploy PrivacyFeeManager
        const FeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        feeManager = await FeeManager.deploy(
            await omniCoin.getAddress(),
            await privateOmniCoin.getAddress(),
            treasury.address,
            owner.address
        );
        await feeManager.waitForDeployment();

        // 5. Deploy Bridge
        const Bridge = await ethers.getContractFactory("OmniCoinPrivacyBridge");
        bridge = await Bridge.deploy(
            await omniCoin.getAddress(),
            await privateOmniCoin.getAddress(),
            await feeManager.getAddress(),
            await registry.getAddress()
        );
        await bridge.waitForDeployment();

        // 6. Register contracts
        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress(),
            "OmniCoin"
        );

        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress(),
            "PrivateOmniCoin"
        );

        await registry.registerContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_BRIDGE")),
            await bridge.getAddress(),
            "Bridge"
        );

        // 7. Grant necessary roles
        const BRIDGE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BRIDGE_ROLE"));
        await privateOmniCoin.grantRole(BRIDGE_ROLE, await bridge.getAddress());
        await omniCoin.grantRole(BRIDGE_ROLE, await bridge.getAddress());

        const FEE_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("FEE_MANAGER_ROLE"));
        await feeManager.grantRole(FEE_MANAGER_ROLE, await bridge.getAddress());

        // 8. Transfer tokens to test users
        await omniCoin.transfer(user1.address, ethers.parseUnits("10000", 6));
        await omniCoin.transfer(user2.address, ethers.parseUnits("10000", 6));
    });

    describe("Initial Setup", function () {
        it("Should deploy all contracts correctly", async function () {
            expect(await registry.getAddress()).to.not.equal(ethers.ZeroAddress);
            expect(await omniCoin.getAddress()).to.not.equal(ethers.ZeroAddress);
            expect(await privateOmniCoin.getAddress()).to.not.equal(ethers.ZeroAddress);
            expect(await feeManager.getAddress()).to.not.equal(ethers.ZeroAddress);
            expect(await bridge.getAddress()).to.not.equal(ethers.ZeroAddress);
        });

        it("Should have correct initial supply", async function () {
            const totalSupply = await omniCoin.totalSupply();
            expect(totalSupply).to.equal(INITIAL_SUPPLY);
        });

        it("Should register contracts correctly", async function () {
            const omniAddress = await registry.getContract(
                ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN"))
            );
            expect(omniAddress).to.equal(await omniCoin.getAddress());
        });
    });

    describe("Public Token (XOM) Operations", function () {
        it("Should transfer tokens without privacy", async function () {
            const balanceBefore = await omniCoin.balanceOf(user2.address);

            await omniCoin.connect(user1).transfer(user2.address, TEST_AMOUNT);

            const balanceAfter = await omniCoin.balanceOf(user2.address);
            expect(balanceAfter - balanceBefore).to.equal(TEST_AMOUNT);
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
            await omniCoin.connect(user1).approve(await bridge.getAddress(), TEST_AMOUNT);

            // Calculate expected amounts
            const fee = TEST_AMOUNT * BRIDGE_FEE / 10000n;
            const expectedPrivate = TEST_AMOUNT - fee;

            // Convert
            const tx = await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
            const receipt = await tx.wait();

            // Check event - ethers v6 uses logs
            const event = receipt.logs.find(log => {
                try {
                    const parsed = bridge.interface.parseLog(log);
                    return parsed && parsed.name === "ConvertedToPrivate";
                } catch {
                    return false;
                }
            });
            expect(event).to.not.be.undefined;
            const parsedEvent = bridge.interface.parseLog(event);
            expect(parsedEvent.args.user).to.equal(user1.address);
            expect(parsedEvent.args.amountIn).to.equal(TEST_AMOUNT);
            expect(parsedEvent.args.amountOut).to.equal(expectedPrivate);
            expect(parsedEvent.args.fee).to.equal(fee);
        });

        it("Should lock XOM in bridge", async function () {
            await omniCoin.connect(user1).approve(await bridge.getAddress(), TEST_AMOUNT);

            const bridgeBalanceBefore = await omniCoin.balanceOf(await bridge.getAddress());
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
            const bridgeBalanceAfter = await omniCoin.balanceOf(await bridge.getAddress());

            expect(bridgeBalanceAfter - bridgeBalanceBefore).to.equal(TEST_AMOUNT);
        });

        it("Should track total conversions", async function () {
            await omniCoin.connect(user1).approve(await bridge.getAddress(), TEST_AMOUNT);

            const totalBefore = await bridge.totalConvertedToPrivate();
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
            const totalAfter = await bridge.totalConvertedToPrivate();

            expect(totalAfter - totalBefore).to.equal(TEST_AMOUNT);
        });
    });

    describe("Bridge Conversion pXOM → XOM", function () {
        beforeEach(async function () {
            // First convert some XOM to pXOM
            await omniCoin.connect(user1).approve(await bridge.getAddress(), TEST_AMOUNT);
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
        });

        it("Should convert private to public without fee", async function () {
            const fee = TEST_AMOUNT * BRIDGE_FEE / 10000n;
            const privateAmount = TEST_AMOUNT - fee;

            const balanceBefore = await omniCoin.balanceOf(user1.address);

            const tx = await bridge.connect(user1).convertToPublic(privateAmount);
            const receipt = await tx.wait();

            const balanceAfter = await omniCoin.balanceOf(user1.address);
            expect(balanceAfter - balanceBefore).to.equal(privateAmount);

            // Check event
            const event = receipt.logs.find(log => {
                try {
                    const parsed = bridge.interface.parseLog(log);
                    return parsed && parsed.name === "ConvertedToPublic";
                } catch {
                    return false;
                }
            });
            expect(event).to.not.be.undefined;
            const parsedEvent = bridge.interface.parseLog(event);
            expect(parsedEvent.args.user).to.equal(user1.address);
            expect(parsedEvent.args.amount).to.equal(privateAmount);
        });

        it("Should maintain 1:1 backing", async function () {
            // Get initial state
            const bridgeBalance = await omniCoin.balanceOf(await bridge.getAddress());
            const privateSupply = await privateOmniCoin.publicTotalSupply();

            // Bridge balance should equal private supply + fees collected
            const totalFees = await bridge.totalFeesCollected();
            expect(bridgeBalance).to.equal(privateSupply + totalFees);
        });
    });

    describe("Fee Management", function () {
        it("Should calculate operation fees correctly", async function () {
            const escrowFee = await feeManager.calculateFee(
                ethers.keccak256(ethers.toUtf8Bytes("ESCROW")),
                TEST_AMOUNT
            );
            expect(escrowFee).to.equal(TEST_AMOUNT * 50n / 10000n); // 0.5%
        });

        it("Should collect public fees", async function () {
            // Grant role to test account
            const FEE_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("FEE_MANAGER_ROLE"));
            await feeManager.grantRole(FEE_MANAGER_ROLE, owner.address);

            // Approve fee payment
            const feeAmount = TEST_AMOUNT * 50n / 10000n;
            await omniCoin.connect(user1).approve(await feeManager.getAddress(), feeAmount);

            const treasuryBefore = await omniCoin.balanceOf(treasury.address);

            await feeManager.collectPublicFee(
                user1.address,
                ethers.keccak256(ethers.toUtf8Bytes("ESCROW")),
                TEST_AMOUNT
            );

            const treasuryAfter = await omniCoin.balanceOf(treasury.address);
            expect(treasuryAfter - treasuryBefore).to.equal(feeAmount);
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
            const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
            await bridge.pause();

            // Try to convert
            await omniCoin.connect(user1).approve(await bridge.getAddress(), TEST_AMOUNT);
            await expect(
                bridge.connect(user1).convertToPrivate(TEST_AMOUNT)
            ).to.be.revertedWith("Pausable: paused");

            // Unpause and retry
            await bridge.unpause();
            await bridge.connect(user1).convertToPrivate(TEST_AMOUNT);
        });
    });
});
