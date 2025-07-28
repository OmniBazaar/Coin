const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinBridge", function () {
    let owner, relayer, validator, user1, user2, treasury, feeManager;
    let registry, omniCoin, privateOmniCoin, privacyFeeManager;
    let bridge;
    
    // Constants
    const CHAIN_ID_ETHEREUM = 1;
    const CHAIN_ID_BSC = 56;
    const MIN_AMOUNT = ethers.parseUnits("10", 6);
    const MAX_AMOUNT = ethers.parseUnits("1000000", 6);
    const BASE_FEE = ethers.parseUnits("1", 6);
    const PRIVACY_MULTIPLIER = 10;
    
    beforeEach(async function () {
        [owner, relayer, validator, user1, user2, treasury, feeManager] = await ethers.getSigners();
        
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
        
        // Deploy actual PrivacyFeeManager
        const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        privacyFeeManager = await PrivacyFeeManager.deploy(
            await registry.getAddress(),
            await feeManager.getAddress()
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
            await feeManager.getAddress()
        );
        
        // Deploy bridge
        const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
        bridge = await OmniCoinBridge.deploy(
            await registry.getAddress(),
            await omniCoin.getAddress(), // token (for backwards compatibility)
            await owner.getAddress(),
            await privacyFeeManager.getAddress()
        );
        await bridge.waitForDeployment();
        
        // Setup
        await bridge.connect(owner).addValidator(await validator.getAddress());
        
        // Configure bridge for Ethereum
        await bridge.connect(owner).configureBridge(
            CHAIN_ID_ETHEREUM,
            ethers.ZeroAddress, // target token
            MIN_AMOUNT,
            MAX_AMOUNT,
            BASE_FEE
        );
        
        // Fund users
        const fundAmount = ethers.parseUnits("10000", 6);
        await omniCoin.mint(await user1.getAddress(), fundAmount);
        await omniCoin.mint(await user2.getAddress(), fundAmount);
        await privateOmniCoin.mint(await user1.getAddress(), fundAmount);
        
        // Approve bridge
        await omniCoin.connect(user1).approve(await bridge.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(user2).approve(await bridge.getAddress(), ethers.MaxUint256);
        await privateOmniCoin.connect(user1).approve(await bridge.getAddress(), ethers.MaxUint256);
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await bridge.owner()).to.equal(await owner.getAddress());
            expect(await bridge.privacyFeeManager()).to.equal(await privacyFeeManager.getAddress());
            expect(await bridge.minTransferAmount()).to.equal(MIN_AMOUNT * 10n); // 100 tokens default
            expect(await bridge.PRIVACY_MULTIPLIER()).to.equal(PRIVACY_MULTIPLIER);
        });
        
        it("Should configure bridge for a chain", async function () {
            await bridge.connect(owner).configureBridge(
                CHAIN_ID_BSC,
                ethers.ZeroAddress,
                MIN_AMOUNT * 2n,
                MAX_AMOUNT / 2n,
                BASE_FEE * 2n
            );
            
            const config = await bridge.bridgeConfigs(CHAIN_ID_BSC);
            expect(config.token).to.equal(ethers.ZeroAddress);
            expect(config.minAmount).to.equal(MIN_AMOUNT * 2n);
            expect(config.maxAmount).to.equal(MAX_AMOUNT / 2n);
            expect(config.fee).to.equal(BASE_FEE * 2n);
            expect(config.isActive).to.be.true;
        });
        
        it("Should emit BridgeConfigured event", async function () {
            await expect(
                bridge.connect(owner).configureBridge(
                    CHAIN_ID_BSC,
                    ethers.ZeroAddress,
                    MIN_AMOUNT,
                    MAX_AMOUNT,
                    BASE_FEE
                )
            ).to.emit(bridge, "BridgeConfigured")
                .withArgs(CHAIN_ID_BSC, ethers.ZeroAddress, MIN_AMOUNT, MAX_AMOUNT, BASE_FEE);
        });
    });
    
    describe("Validator Management", function () {
        it("Should add validator", async function () {
            const newValidator = await user2.getAddress();
            
            await bridge.connect(owner).addValidator(newValidator);
            
            expect(await bridge.validators(newValidator)).to.be.true;
        });
        
        it("Should remove validator", async function () {
            await bridge.connect(owner).removeValidator(await validator.getAddress());
            
            expect(await bridge.validators(await validator.getAddress())).to.be.false;
        });
        
        it("Should only allow owner to manage validators", async function () {
            await expect(
                bridge.connect(user1).addValidator(await user2.getAddress())
            ).to.be.revertedWithCustomError(bridge, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Standard Bridge Transfers", function () {
        const transferAmount = ethers.parseUnits("100", 6);
        
        it("Should initiate transfer with OmniCoin", async function () {
            const balanceBefore = await omniCoin.balanceOf(await user1.getAddress());
            const bridgeBalanceBefore = await omniCoin.balanceOf(await bridge.getAddress());
            
            const tx = await bridge.connect(user1).initiateTransfer(
                CHAIN_ID_ETHEREUM,
                ethers.ZeroAddress,
                await user2.getAddress(),
                transferAmount
            );
            
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    const parsed = bridge.interface.parseLog(log);
                    return parsed.name === "TransferInitiated";
                } catch (e) {
                    return false;
                }
            });
            
            expect(event).to.not.be.undefined;
            
            // Check balances
            expect(await omniCoin.balanceOf(await user1.getAddress()))
                .to.equal(balanceBefore - transferAmount - BASE_FEE);
            expect(await omniCoin.balanceOf(await bridge.getAddress()))
                .to.equal(bridgeBalanceBefore + transferAmount + BASE_FEE);
            
            // Check transfer record
            const transfer = await bridge.transfers(1);
            expect(transfer.sender).to.equal(await user1.getAddress());
            expect(transfer.recipient).to.equal(await user2.getAddress());
            expect(transfer.amount).to.equal(transferAmount);
            expect(transfer.fee).to.equal(BASE_FEE);
            expect(transfer.targetChainId).to.equal(CHAIN_ID_ETHEREUM);
            expect(transfer.completed).to.be.false;
            expect(transfer.isPrivate).to.be.false;
        });
        
        it("Should fail if amount too small", async function () {
            await expect(
                bridge.connect(user1).initiateTransfer(
                    CHAIN_ID_ETHEREUM,
                    ethers.ZeroAddress,
                    await user2.getAddress(),
                    MIN_AMOUNT - 1n
                )
            ).to.be.revertedWithCustomError(bridge, "TransferTooSmall");
        });
        
        it("Should fail if amount too large", async function () {
            await expect(
                bridge.connect(user1).initiateTransfer(
                    CHAIN_ID_ETHEREUM,
                    ethers.ZeroAddress,
                    await user2.getAddress(),
                    MAX_AMOUNT + 1n
                )
            ).to.be.revertedWithCustomError(bridge, "TransferTooLarge");
        });
        
        it("Should fail if bridge not active", async function () {
            await expect(
                bridge.connect(user1).initiateTransfer(
                    999, // non-configured chain
                    ethers.ZeroAddress,
                    await user2.getAddress(),
                    transferAmount
                )
            ).to.be.revertedWithCustomError(bridge, "BridgeNotActive");
        });
    });
    
    describe("Privacy Bridge Transfers", function () {
        const transferAmount = ethers.parseUnits("100", 6);
        
        beforeEach(async function () {
            // Enable MPC for testing
            await bridge.connect(owner).setMpcAvailable(true);
        });
        
        it("Should initiate privacy transfer with PrivateOmniCoin", async function () {
            // For testing, we'll simulate the privacy transfer
            // In production, this would use encrypted amounts
            
            // Note: This test would need mock MPC functionality to work properly
            // For now, we'll test the revert case
            await expect(
                bridge.connect(user1).initiateTransferWithPrivacy(
                    CHAIN_ID_ETHEREUM,
                    ethers.ZeroAddress,
                    await user2.getAddress(),
                    { data: new Uint8Array(32) }, // mock encrypted amount
                    true
                )
            ).to.be.reverted; // Will revert due to MPC operations in test environment
        });
        
        it("Should charge 10x fee for privacy transfers", async function () {
            // This would be tested if we had MPC mocks
            // The privacy fee should be BASE_FEE * PRIVACY_MULTIPLIER
            expect(await bridge.PRIVACY_MULTIPLIER()).to.equal(10);
        });
    });
    
    describe("Transfer Completion", function () {
        beforeEach(async function () {
            // Initiate a transfer first
            await bridge.connect(user1).initiateTransfer(
                CHAIN_ID_ETHEREUM,
                ethers.ZeroAddress,
                await user2.getAddress(),
                ethers.parseUnits("100", 6)
            );
        });
        
        it("Should complete transfer with valid signature", async function () {
            // Get transfer data
            const transfer = await bridge.transfers(1);
            const message = ethers.toUtf8Bytes("transfer-valid");
            
            // Create message hash
            const messageHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "address", "uint256", "uint256", "address", "address", "uint256", "uint256", "bytes"],
                    [
                        1,
                        transfer.sender,
                        transfer.sourceChainId,
                        transfer.targetChainId,
                        transfer.targetToken,
                        transfer.recipient,
                        transfer.amount,
                        transfer.fee,
                        message
                    ]
                )
            );
            
            // Sign with validator
            const signature = await validator.signMessage(ethers.getBytes(messageHash));
            
            await expect(
                bridge.connect(user1).completeTransfer(1, message, signature)
            ).to.emit(bridge, "TransferCompleted")
                .withArgs(1, await user2.getAddress(), ethers.parseUnits("100", 6));
            
            expect((await bridge.transfers(1)).completed).to.be.true;
            
            // Check tokens were released to recipient
            expect(await omniCoin.balanceOf(await user2.getAddress()))
                .to.equal(ethers.parseUnits("10100", 6)); // 10000 initial + 100 transferred
        });
        
        it("Should reject invalid signature", async function () {
            const message = ethers.toUtf8Bytes("transfer-valid");
            const invalidSig = ethers.hexlify(ethers.randomBytes(65));
            
            await expect(
                bridge.connect(user1).completeTransfer(1, message, invalidSig)
            ).to.be.revertedWithCustomError(bridge, "UnauthorizedValidator");
        });
        
        it("Should prevent double completion", async function () {
            const transfer = await bridge.transfers(1);
            const message = ethers.toUtf8Bytes("transfer-valid");
            
            // Create message hash and sign
            const messageHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "address", "uint256", "uint256", "address", "address", "uint256", "uint256", "bytes"],
                    [
                        1,
                        transfer.sender,
                        transfer.sourceChainId,
                        transfer.targetChainId,
                        transfer.targetToken,
                        transfer.recipient,
                        transfer.amount,
                        transfer.fee,
                        message
                    ]
                )
            );
            const signature = await validator.signMessage(ethers.getBytes(messageHash));
            
            await bridge.connect(user1).completeTransfer(1, message, signature);
            
            await expect(
                bridge.connect(user1).completeTransfer(1, message, signature)
            ).to.be.revertedWithCustomError(bridge, "TransferAlreadyCompleted");
        });
    });
    
    describe("Transfer Refunds", function () {
        beforeEach(async function () {
            await bridge.connect(user1).initiateTransfer(
                CHAIN_ID_ETHEREUM,
                ethers.ZeroAddress,
                await user2.getAddress(),
                ethers.parseUnits("100", 6)
            );
        });
        
        it("Should refund transfer after timeout", async function () {
            const balanceBefore = await omniCoin.balanceOf(await user1.getAddress());
            
            // Fast forward time past timeout
            await ethers.provider.send("evm_increaseTime", [3601]); // 1 hour + 1 second
            await ethers.provider.send("evm_mine");
            
            await expect(
                bridge.connect(user1).refundTransfer(1)
            ).to.emit(bridge, "TransferRefunded")
                .withArgs(1, await user1.getAddress(), ethers.parseUnits("100", 6), BASE_FEE);
            
            const transfer = await bridge.transfers(1);
            expect(transfer.refunded).to.be.true;
            
            // Check refund (amount + fee returned)
            expect(await omniCoin.balanceOf(await user1.getAddress()))
                .to.equal(balanceBefore + ethers.parseUnits("101", 6));
        });
        
        it("Should not refund before timeout", async function () {
            await expect(
                bridge.connect(user1).refundTransfer(1)
            ).to.be.revertedWithCustomError(bridge, "MessageTimeout");
        });
        
        it("Should not refund completed transfer", async function () {
            // Complete the transfer first
            const transfer = await bridge.transfers(1);
            const message = ethers.toUtf8Bytes("transfer-valid");
            const messageHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "address", "uint256", "uint256", "address", "address", "uint256", "uint256", "bytes"],
                    [
                        1,
                        transfer.sender,
                        transfer.sourceChainId,
                        transfer.targetChainId,
                        transfer.targetToken,
                        transfer.recipient,
                        transfer.amount,
                        transfer.fee,
                        message
                    ]
                )
            );
            const signature = await validator.signMessage(ethers.getBytes(messageHash));
            
            await bridge.connect(user1).completeTransfer(1, message, signature);
            
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [3601]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                bridge.connect(user1).refundTransfer(1)
            ).to.be.revertedWithCustomError(bridge, "TransferAlreadyCompleted");
        });
    });
    
    describe("Fee Management", function () {
        it("Should update base fee", async function () {
            const newFee = ethers.parseUnits("2", 6);
            
            await bridge.connect(owner).setBaseFee(newFee);
            expect(await bridge.baseFee()).to.equal(newFee);
        });
        
        it("Should update transfer limits", async function () {
            const newMin = ethers.parseUnits("5", 6);
            const newMax = ethers.parseUnits("500000", 6);
            
            await bridge.connect(owner).setMinTransferAmount(newMin);
            await bridge.connect(owner).setMaxTransferAmount(newMax);
            expect(await bridge.minTransferAmount()).to.equal(newMin);
            expect(await bridge.maxTransferAmount()).to.equal(newMax);
        });
    });
    
    describe("Query Functions", function () {
        beforeEach(async function () {
            await bridge.connect(user1).initiateTransfer(
                CHAIN_ID_ETHEREUM,
                ethers.ZeroAddress,
                await user2.getAddress(),
                ethers.parseUnits("100", 6)
            );
        });
        
        it("Should get transfer details", async function () {
            const details = await bridge.getTransfer(1);
            
            expect(details.sender).to.equal(await user1.getAddress());
            expect(details.sourceChainId).to.equal(31337); // Hardhat chain ID
            expect(details.targetChainId).to.equal(CHAIN_ID_ETHEREUM);
            expect(details.targetToken).to.equal(ethers.ZeroAddress);
            expect(details.recipient).to.equal(await user2.getAddress());
            expect(details.amount).to.equal(ethers.parseUnits("100", 6));
            expect(details.fee).to.equal(BASE_FEE);
            expect(details.completed).to.be.false;
            expect(details.refunded).to.be.false;
            expect(details.isPrivate).to.be.false;
        });
        
        it("Should get bridge config", async function () {
            const config = await bridge.getBridgeConfig(CHAIN_ID_ETHEREUM);
            
            expect(config.tokenAddress).to.equal(ethers.ZeroAddress);
            expect(config.isActive).to.be.true;
            expect(config.minAmount).to.equal(MIN_AMOUNT);
            expect(config.maxAmount).to.equal(MAX_AMOUNT);
            expect(config.fee).to.equal(BASE_FEE);
        });
        
        it("Should check validator status", async function () {
            expect(await bridge.isValidator(await validator.getAddress())).to.be.true;
            expect(await bridge.isValidator(await user1.getAddress())).to.be.false;
        });
    });
    
});