const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinAccount", function () {
    let owner, operator, guardian, user1, user2, treasury;
    let registry, entryPoint, omniCoin, privateOmniCoin;
    let accountFactory, accountImplementation;
    let userAccount;
    
    // Constants
    const ACCOUNT_VERSION = "1.0.0";
    const MIN_BALANCE = ethers.parseUnits("10", 6); // 10 tokens
    
    beforeEach(async function () {
        [owner, operator, guardian, user1, user2, treasury] = await ethers.getSigners();
        
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
        
        // Deploy EntryPoint from coti-contracts if available, otherwise create a minimal implementation
        try {
            const EntryPoint = await ethers.getContractFactory("EntryPoint");
            entryPoint = await EntryPoint.deploy();
            await entryPoint.waitForDeployment();
        } catch (e) {
            // Create minimal EntryPoint implementation for testing
            const minimalEntryPoint = await ethers.deployContract(
                "contracts/test/MinimalEntryPoint.sol:MinimalEntryPoint"
            );
            entryPoint = minimalEntryPoint;
            await entryPoint.waitForDeployment();
        }
        
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
        
        // Deploy OmniCoinAccount directly for user1
        const OmniCoinAccount = await ethers.getContractFactory("OmniCoinAccount");
        userAccount = await OmniCoinAccount.deploy();
        await userAccount.waitForDeployment();
        
        // Initialize the account
        await userAccount.initialize(
            await registry.getAddress(),
            await entryPoint.getAddress(),
            await omniCoin.getAddress()
        );
        
        // Register the account in the registry if needed
        // This could be done if accounts need to be discoverable
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("ACCOUNT_" + await user1.getAddress())),
            await userAccount.getAddress()
        );
        
        // Fund the account
        await omniCoin.mint(await userAccount.getAddress(), ethers.parseUnits("1000", 6));
        await privateOmniCoin.mint(await userAccount.getAddress(), ethers.parseUnits("1000", 6));
    });
    
    describe("Account Creation", function () {
        it("Should create account with correct initial values", async function () {
            expect(await userAccount.owner()).to.equal(await user1.getAddress());
            expect(await userAccount.entryPoint()).to.equal(await entryPoint.getAddress());
            
            const version = await userAccount.version();
            expect(version).to.equal(ACCOUNT_VERSION);
        });
        
        it("Should create unique accounts for different users", async function () {
            // Deploy another account for user2
            const OmniCoinAccount = await ethers.getContractFactory("OmniCoinAccount");
            const user2Account = await OmniCoinAccount.deploy();
            await user2Account.waitForDeployment();
            
            await user2Account.initialize(
                await registry.getAddress(),
                await entryPoint.getAddress(),
                await omniCoin.getAddress()
            );
            
            expect(await user2Account.getAddress()).to.not.equal(await userAccount.getAddress());
            expect(await user2Account.owner()).to.equal(await user2.getAddress());
        });
        
        it("Should allow deterministic deployment with CREATE2", async function () {
            // If deterministic addresses are needed, we can use CREATE2 directly
            // For now, we'll skip this test since no factory is used
            // In production, accounts might be deployed via registry or another mechanism
            this.skip();
        });
    });
    
    describe("Transaction Execution", function () {
        it("Should execute single transaction", async function () {
            const amount = ethers.parseUnits("50", 6);
            const balanceBefore = await omniCoin.balanceOf(await user2.getAddress());
            
            // Prepare transfer calldata
            const transferCalldata = omniCoin.interface.encodeFunctionData(
                "transfer",
                [await user2.getAddress(), amount]
            );
            
            await expect(
                userAccount.connect(user1).execute(
                    await omniCoin.getAddress(),
                    0, // value
                    transferCalldata
                )
            ).to.emit(userAccount, "Executed")
                .withArgs(await omniCoin.getAddress(), 0, transferCalldata);
            
            expect(await omniCoin.balanceOf(await user2.getAddress()))
                .to.equal(balanceBefore + amount);
        });
        
        it("Should execute batch transactions", async function () {
            const amount1 = ethers.parseUnits("30", 6);
            const amount2 = ethers.parseUnits("20", 6);
            
            const targets = [
                await omniCoin.getAddress(),
                await omniCoin.getAddress()
            ];
            
            const values = [0, 0];
            
            const calldatas = [
                omniCoin.interface.encodeFunctionData("transfer", [await user2.getAddress(), amount1]),
                omniCoin.interface.encodeFunctionData("transfer", [await guardian.getAddress(), amount2])
            ];
            
            await userAccount.connect(user1).executeBatch(targets, values, calldatas);
            
            expect(await omniCoin.balanceOf(await user2.getAddress())).to.equal(amount1);
            expect(await omniCoin.balanceOf(await guardian.getAddress())).to.equal(amount2);
        });
        
        it("Should only allow owner to execute", async function () {
            const transferCalldata = omniCoin.interface.encodeFunctionData(
                "transfer",
                [await user2.getAddress(), 100]
            );
            
            await expect(
                userAccount.connect(user2).execute(
                    await omniCoin.getAddress(),
                    0,
                    transferCalldata
                )
            ).to.be.revertedWithCustomError(userAccount, "UnauthorizedCaller");
        });
    });
    
    describe("Guardian Management", function () {
        it("Should add guardian", async function () {
            await expect(
                userAccount.connect(user1).addGuardian(await guardian.getAddress())
            ).to.emit(userAccount, "GuardianAdded")
                .withArgs(await guardian.getAddress());
            
            expect(await userAccount.isGuardian(await guardian.getAddress())).to.be.true;
        });
        
        it("Should remove guardian", async function () {
            await userAccount.connect(user1).addGuardian(await guardian.getAddress());
            
            await expect(
                userAccount.connect(user1).removeGuardian(await guardian.getAddress())
            ).to.emit(userAccount, "GuardianRemoved")
                .withArgs(await guardian.getAddress());
            
            expect(await userAccount.isGuardian(await guardian.getAddress())).to.be.false;
        });
        
        it("Should only allow owner to manage guardians", async function () {
            await expect(
                userAccount.connect(user2).addGuardian(await guardian.getAddress())
            ).to.be.revertedWithCustomError(userAccount, "UnauthorizedCaller");
        });
    });
    
    describe("Recovery Features", function () {
        beforeEach(async function () {
            // Add guardian
            await userAccount.connect(user1).addGuardian(await guardian.getAddress());
        });
        
        it("Should initiate recovery", async function () {
            const newOwner = await user2.getAddress();
            
            await expect(
                userAccount.connect(guardian).initiateRecovery(newOwner)
            ).to.emit(userAccount, "RecoveryInitiated")
                .withArgs(newOwner, await guardian.getAddress());
            
            const recovery = await userAccount.pendingRecovery();
            expect(recovery.newOwner).to.equal(newOwner);
            expect(recovery.guardian).to.equal(await guardian.getAddress());
        });
        
        it("Should execute recovery after delay", async function () {
            const newOwner = await user2.getAddress();
            
            await userAccount.connect(guardian).initiateRecovery(newOwner);
            
            // Fast forward time (48 hours default recovery delay)
            await ethers.provider.send("evm_increaseTime", [48 * 3600]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                userAccount.connect(guardian).executeRecovery()
            ).to.emit(userAccount, "RecoveryExecuted")
                .withArgs(newOwner);
            
            expect(await userAccount.owner()).to.equal(newOwner);
        });
        
        it("Should cancel recovery by owner", async function () {
            await userAccount.connect(guardian).initiateRecovery(await user2.getAddress());
            
            await expect(
                userAccount.connect(user1).cancelRecovery()
            ).to.emit(userAccount, "RecoveryCancelled");
            
            const recovery = await userAccount.pendingRecovery();
            expect(recovery.newOwner).to.equal(ethers.ZeroAddress);
        });
        
        it("Should not execute recovery before delay", async function () {
            await userAccount.connect(guardian).initiateRecovery(await user2.getAddress());
            
            await expect(
                userAccount.connect(guardian).executeRecovery()
            ).to.be.revertedWithCustomError(userAccount, "RecoveryDelayNotMet");
        });
    });
    
    describe("Session Keys", function () {
        const sessionDuration = 24 * 3600; // 24 hours
        
        it("Should add session key", async function () {
            const permissions = ethers.keccak256(ethers.toUtf8Bytes("transfer-only"));
            const validUntil = Math.floor(Date.now() / 1000) + sessionDuration;
            
            await expect(
                userAccount.connect(user1).addSessionKey(
                    await operator.getAddress(),
                    permissions,
                    validUntil
                )
            ).to.emit(userAccount, "SessionKeyAdded")
                .withArgs(await operator.getAddress(), permissions, validUntil);
            
            const session = await userAccount.sessionKeys(await operator.getAddress());
            expect(session.permissions).to.equal(permissions);
            expect(session.validUntil).to.equal(validUntil);
            expect(session.isActive).to.be.true;
        });
        
        it("Should execute with valid session key", async function () {
            const permissions = ethers.keccak256(ethers.toUtf8Bytes("transfer-only"));
            const validUntil = Math.floor(Date.now() / 1000) + sessionDuration;
            
            await userAccount.connect(user1).addSessionKey(
                await operator.getAddress(),
                permissions,
                validUntil
            );
            
            const amount = ethers.parseUnits("10", 6);
            const transferCalldata = omniCoin.interface.encodeFunctionData(
                "transfer",
                [await user2.getAddress(), amount]
            );
            
            await expect(
                userAccount.connect(operator).executeWithSession(
                    await omniCoin.getAddress(),
                    0,
                    transferCalldata
                )
            ).to.emit(userAccount, "SessionExecuted")
                .withArgs(await operator.getAddress(), await omniCoin.getAddress());
        });
        
        it("Should revoke session key", async function () {
            const permissions = ethers.keccak256(ethers.toUtf8Bytes("transfer-only"));
            const validUntil = Math.floor(Date.now() / 1000) + sessionDuration;
            
            await userAccount.connect(user1).addSessionKey(
                await operator.getAddress(),
                permissions,
                validUntil
            );
            
            await expect(
                userAccount.connect(user1).revokeSessionKey(await operator.getAddress())
            ).to.emit(userAccount, "SessionKeyRevoked")
                .withArgs(await operator.getAddress());
            
            const session = await userAccount.sessionKeys(await operator.getAddress());
            expect(session.isActive).to.be.false;
        });
    });
    
    describe("Privacy and Staking", function () {
        it("Should toggle privacy mode", async function () {
            await expect(
                userAccount.togglePrivacy()
            ).to.emit(userAccount, "PrivacyToggled")
                .withArgs(await owner.getAddress(), true);
            
            // Toggle again
            await expect(
                userAccount.togglePrivacy()
            ).to.emit(userAccount, "PrivacyToggled")
                .withArgs(await owner.getAddress(), false);
        });
        
        it("Should update staking amount", async function () {
            const amount = ethers.parseUnits("100", 6);
            
            // Approve tokens first
            await omniCoin.approve(await userAccount.getAddress(), amount);
            
            await expect(
                userAccount.updateStaking(amount, false)
            ).to.emit(userAccount, "StakingUpdated")
                .withArgs(await owner.getAddress(), amount);
        });
    });
    
    describe("EntryPoint Configuration", function () {
        it("Should update entry point", async function () {
            const newEntryPoint = await user2.getAddress(); // Just for testing
            
            await expect(
                userAccount.updateEntryPoint(newEntryPoint)
            ).to.emit(userAccount, "EntryPointUpdated")
                .withArgs(newEntryPoint);
            
            expect(await userAccount.entryPoint()).to.equal(newEntryPoint);
        });
        
        it("Should update gas limit", async function () {
            const newGasLimit = 2000000;
            
            await expect(
                userAccount.updateGasLimit(newGasLimit)
            ).to.emit(userAccount, "GasLimitUpdated")
                .withArgs(newGasLimit);
            
            expect(await userAccount.entryPointGasLimit()).to.equal(newGasLimit);
        });
    });
    
    describe("EntryPoint Integration", function () {
        it("Should validate user operation", async function () {
            // This would test ERC-4337 UserOperation validation
            // Simplified for mock testing
            const userOp = {
                sender: await userAccount.getAddress(),
                nonce: 0,
                initCode: "0x",
                callData: "0x",
                callGasLimit: 100000,
                verificationGasLimit: 100000,
                preVerificationGas: 50000,
                maxFeePerGas: ethers.parseUnits("10", "gwei"),
                maxPriorityFeePerGas: ethers.parseUnits("1", "gwei"),
                paymasterAndData: "0x",
                signature: "0x"
            };
            
            const userOpHash = ethers.keccak256(ethers.toUtf8Bytes("mock-op-hash"));
            const missingFunds = 0;
            
            // This would normally be called by EntryPoint
            // For testing, we just verify it doesn't revert
            await expect(
                userAccount.validateUserOp(userOp, userOpHash, missingFunds)
            ).to.not.be.reverted;
        });
    });
    
    describe("Upgrade Functionality", function () {
        it("Should upgrade implementation", async function () {
            // Deploy new implementation
            const OmniCoinAccountV2 = await ethers.getContractFactory("OmniCoinAccount");
            const newImplementation = await OmniCoinAccountV2.deploy();
            await newImplementation.waitForDeployment();
            
            await expect(
                userAccount.connect(user1).upgradeTo(await newImplementation.getAddress())
            ).to.emit(userAccount, "Upgraded")
                .withArgs(await newImplementation.getAddress());
        });
        
        it("Should only allow owner to upgrade", async function () {
            const OmniCoinAccountV2 = await ethers.getContractFactory("OmniCoinAccount");
            const newImplementation = await OmniCoinAccountV2.deploy();
            await newImplementation.waitForDeployment();
            
            await expect(
                userAccount.connect(user2).upgradeTo(await newImplementation.getAddress())
            ).to.be.revertedWithCustomError(userAccount, "UnauthorizedCaller");
        });
    });
});