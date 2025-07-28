const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinMultisig", function () {
    let owner, signer1, signer2, signer3, signer4, user, treasury;
    let registry, omniCoin;
    let multisig;
    let testTarget;
    
    // Constants
    const DEFAULT_MIN_SIGNATURES = 2;
    const DEFAULT_SIGNER_TIMEOUT = 24 * 60 * 60; // 1 day
    
    beforeEach(async function () {
        [owner, signer1, signer2, signer3, signer4, user, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin (may be needed for some tests)
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        
        // Deploy OmniCoinMultisig
        const OmniCoinMultisig = await ethers.getContractFactory("OmniCoinMultisig");
        multisig = await OmniCoinMultisig.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await multisig.waitForDeployment();
        
        // Deploy test target
        const TestTarget = await ethers.getContractFactory("contracts/test/TestTarget.sol:TestTarget");
        testTarget = await TestTarget.deploy();
        await testTarget.waitForDeployment();
        
        // Setup signers
        await multisig.connect(owner).addSigner(await signer1.getAddress());
        await multisig.connect(owner).addSigner(await signer2.getAddress());
        await multisig.connect(owner).addSigner(await signer3.getAddress());
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await multisig.owner()).to.equal(await owner.getAddress());
            expect(await multisig.minSignatures()).to.equal(DEFAULT_MIN_SIGNATURES);
            expect(await multisig.signerTimeout()).to.equal(DEFAULT_SIGNER_TIMEOUT);
            expect(await multisig.transactionCount()).to.equal(0);
        });
        
        it("Should have correct initial signers", async function () {
            const activeSigners = await multisig.getActiveSigners();
            expect(activeSigners.length).to.equal(3);
            expect(activeSigners).to.include(await signer1.getAddress());
            expect(activeSigners).to.include(await signer2.getAddress());
            expect(activeSigners).to.include(await signer3.getAddress());
        });
        
        it("Should update minimum signatures", async function () {
            const newMinSigs = 3;
            
            await expect(multisig.connect(owner).setMinSignatures(newMinSigs))
                .to.emit(multisig, "MinSignaturesUpdated")
                .withArgs(DEFAULT_MIN_SIGNATURES, newMinSigs);
            
            expect(await multisig.minSignatures()).to.equal(newMinSigs);
        });
        
        it("Should not set minimum signatures to zero", async function () {
            await expect(
                multisig.connect(owner).setMinSignatures(0)
            ).to.be.revertedWithCustomError(multisig, "InvalidMinSignatures");
        });
        
        it("Should not set minimum signatures above signer count", async function () {
            await expect(
                multisig.connect(owner).setMinSignatures(4) // Only 3 signers
            ).to.be.revertedWithCustomError(multisig, "TooManySignatures");
        });
        
        it("Should update signer timeout", async function () {
            const newTimeout = 48 * 60 * 60; // 2 days
            
            await expect(multisig.connect(owner).setSignerTimeout(newTimeout))
                .to.emit(multisig, "SignerTimeoutUpdated")
                .withArgs(DEFAULT_SIGNER_TIMEOUT, newTimeout);
            
            expect(await multisig.signerTimeout()).to.equal(newTimeout);
        });
    });
    
    describe("Signer Management", function () {
        it("Should add new signer", async function () {
            await expect(multisig.connect(owner).addSigner(await signer4.getAddress()))
                .to.emit(multisig, "SignerAdded")
                .withArgs(await signer4.getAddress());
            
            expect(await multisig.isActiveSigner(await signer4.getAddress())).to.be.true;
            
            const signerInfo = await multisig.getSigner(await signer4.getAddress());
            expect(signerInfo.isActive).to.be.true;
            expect(signerInfo.signer).to.equal(await signer4.getAddress());
            
            const activeSigners = await multisig.getActiveSigners();
            expect(activeSigners).to.include(await signer4.getAddress());
            expect(activeSigners.length).to.equal(4);
        });
        
        it("Should not add zero address as signer", async function () {
            await expect(
                multisig.connect(owner).addSigner(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(multisig, "ZeroTarget");
        });
        
        it("Should not add duplicate signer", async function () {
            await expect(
                multisig.connect(owner).addSigner(await signer1.getAddress())
            ).to.be.revertedWithCustomError(multisig, "AlreadyActiveSigner");
        });
        
        it("Should remove signer", async function () {
            await expect(multisig.connect(owner).removeSigner(await signer3.getAddress()))
                .to.emit(multisig, "SignerRemoved")
                .withArgs(await signer3.getAddress());
            
            expect(await multisig.isActiveSigner(await signer3.getAddress())).to.be.false;
            
            const activeSigners = await multisig.getActiveSigners();
            expect(activeSigners).to.not.include(await signer3.getAddress());
            expect(activeSigners.length).to.equal(2);
        });
        
        it("Should not remove non-existent signer", async function () {
            await expect(
                multisig.connect(owner).removeSigner(await user.getAddress())
            ).to.be.revertedWithCustomError(multisig, "NotSigner");
        });
        
        it("Should update signer activity", async function () {
            const initialActivity = (await multisig.getSigner(await signer1.getAddress())).lastActive;
            
            // Wait a bit
            await ethers.provider.send("evm_increaseTime", [60]);
            await ethers.provider.send("evm_mine");
            
            await multisig.connect(user).updateSignerActivity(await signer1.getAddress());
            
            const updatedActivity = (await multisig.getSigner(await signer1.getAddress())).lastActive;
            expect(updatedActivity).to.be.gt(initialActivity);
        });
    });
    
    describe("Transaction Creation", function () {
        it("Should create transaction", async function () {
            const target = await testTarget.getAddress();
            const data = testTarget.interface.encodeFunctionData("setValue", [42]);
            const value = ethers.parseEther("0.1");
            const requiredSigs = 2;
            
            await expect(
                multisig.connect(owner).createTransaction(target, data, value, requiredSigs)
            ).to.emit(multisig, "TransactionCreated")
                .withArgs(0, target, data, value, requiredSigs);
            
            expect(await multisig.transactionCount()).to.equal(1);
            
            const tx = await multisig.getTransaction(0);
            expect(tx.id).to.equal(0);
            expect(tx.target).to.equal(target);
            expect(tx.data).to.equal(data);
            expect(tx.value).to.equal(value);
            expect(tx.requiredSignatures).to.equal(requiredSigs);
            expect(tx.signatureCount).to.equal(0);
            expect(tx.executed).to.be.false;
            expect(tx.canceled).to.be.false;
        });
        
        it("Should not create transaction with zero target", async function () {
            await expect(
                multisig.connect(owner).createTransaction(
                    ethers.ZeroAddress,
                    "0x",
                    0,
                    2
                )
            ).to.be.revertedWithCustomError(multisig, "ZeroTarget");
        });
        
        it("Should not create transaction with insufficient signatures", async function () {
            await expect(
                multisig.connect(owner).createTransaction(
                    await testTarget.getAddress(),
                    "0x",
                    0,
                    1 // Below minimum
                )
            ).to.be.revertedWithCustomError(multisig, "InsufficientSignatures");
        });
        
        it("Should not create transaction with too many signatures", async function () {
            await expect(
                multisig.connect(owner).createTransaction(
                    await testTarget.getAddress(),
                    "0x",
                    0,
                    4 // More than signers
                )
            ).to.be.revertedWithCustomError(multisig, "TooManySignatures");
        });
        
        it("Should only allow owner to create transaction", async function () {
            await expect(
                multisig.connect(signer1).createTransaction(
                    await testTarget.getAddress(),
                    "0x",
                    0,
                    2
                )
            ).to.be.revertedWithCustomError(multisig, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Transaction Signing", function () {
        let txId;
        
        beforeEach(async function () {
            const target = await testTarget.getAddress();
            const data = testTarget.interface.encodeFunctionData("setValue", [42]);
            await multisig.connect(owner).createTransaction(target, data, 0, 2);
            txId = 0;
        });
        
        it("Should sign transaction", async function () {
            await expect(multisig.connect(signer1).signTransaction(txId))
                .to.emit(multisig, "TransactionSigned")
                .withArgs(txId, await signer1.getAddress());
            
            expect(await multisig.hasSigned(txId, await signer1.getAddress())).to.be.true;
            
            const tx = await multisig.getTransaction(txId);
            expect(tx.signatureCount).to.equal(1);
        });
        
        it("Should sign with multiple signers", async function () {
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            
            const tx = await multisig.getTransaction(txId);
            expect(tx.signatureCount).to.equal(2);
            
            expect(await multisig.hasSigned(txId, await signer1.getAddress())).to.be.true;
            expect(await multisig.hasSigned(txId, await signer2.getAddress())).to.be.true;
        });
        
        it("Should not allow double signing", async function () {
            await multisig.connect(signer1).signTransaction(txId);
            
            await expect(
                multisig.connect(signer1).signTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "AlreadySigned");
        });
        
        it("Should not allow non-signer to sign", async function () {
            await expect(
                multisig.connect(user).signTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "NotSigner");
        });
        
        it("Should not sign executed transaction", async function () {
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            await multisig.connect(user).executeTransaction(txId);
            
            await expect(
                multisig.connect(signer3).signTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "TransactionAlreadyExecuted");
        });
        
        it("Should not sign canceled transaction", async function () {
            await multisig.connect(owner).cancelTransaction(txId);
            
            await expect(
                multisig.connect(signer1).signTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "TransactionCanceled");
        });
    });
    
    describe("Transaction Execution", function () {
        let txId;
        
        beforeEach(async function () {
            const target = await testTarget.getAddress();
            const data = testTarget.interface.encodeFunctionData("setValue", [42]);
            await multisig.connect(owner).createTransaction(target, data, 0, 2);
            txId = 0;
        });
        
        it("Should execute transaction after sufficient signatures", async function () {
            expect(await testTarget.value()).to.equal(0);
            
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            
            await expect(multisig.connect(user).executeTransaction(txId))
                .to.emit(multisig, "TransactionExecuted")
                .withArgs(txId);
            
            expect(await testTarget.value()).to.equal(42);
            
            const tx = await multisig.getTransaction(txId);
            expect(tx.executed).to.be.true;
        });
        
        it("Should execute transaction with ETH value", async function () {
            const value = ethers.parseEther("1");
            const target = await testTarget.getAddress();
            const data = testTarget.interface.encodeFunctionData("receiveEther");
            
            // Fund multisig
            await owner.sendTransaction({
                to: await multisig.getAddress(),
                value: value
            });
            
            await multisig.connect(owner).createTransaction(target, data, value, 2);
            const newTxId = 1;
            
            await multisig.connect(signer1).signTransaction(newTxId);
            await multisig.connect(signer2).signTransaction(newTxId);
            
            const balanceBefore = await ethers.provider.getBalance(target);
            
            await multisig.connect(user).executeTransaction(newTxId);
            
            const balanceAfter = await ethers.provider.getBalance(target);
            expect(balanceAfter - balanceBefore).to.equal(value);
        });
        
        it("Should not execute without sufficient signatures", async function () {
            await multisig.connect(signer1).signTransaction(txId); // Only 1 of 2 required
            
            await expect(
                multisig.connect(user).executeTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "InsufficientSignatures");
        });
        
        it("Should not execute already executed transaction", async function () {
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            await multisig.connect(user).executeTransaction(txId);
            
            await expect(
                multisig.connect(user).executeTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "TransactionAlreadyExecuted");
        });
        
        it("Should not execute canceled transaction", async function () {
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            await multisig.connect(owner).cancelTransaction(txId);
            
            await expect(
                multisig.connect(user).executeTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "TransactionCanceled");
        });
        
        it("Should revert if transaction execution fails", async function () {
            // Create transaction that will fail
            const data = testTarget.interface.encodeFunctionData("setValue", [42]);
            await multisig.connect(owner).createTransaction(
                await testTarget.getAddress(),
                data,
                ethers.parseEther("1"), // Send ETH but target doesn't accept it
                2
            );
            const failingTxId = 1;
            
            await multisig.connect(signer1).signTransaction(failingTxId);
            await multisig.connect(signer2).signTransaction(failingTxId);
            
            await expect(
                multisig.connect(user).executeTransaction(failingTxId)
            ).to.be.revertedWithCustomError(multisig, "TransactionExecutionFailed");
        });
    });
    
    describe("Transaction Cancellation", function () {
        let txId;
        
        beforeEach(async function () {
            const target = await testTarget.getAddress();
            const data = testTarget.interface.encodeFunctionData("setValue", [42]);
            await multisig.connect(owner).createTransaction(target, data, 0, 2);
            txId = 0;
        });
        
        it("Should cancel transaction", async function () {
            await expect(multisig.connect(owner).cancelTransaction(txId))
                .to.emit(multisig, "TransactionCancelledEvent")
                .withArgs(txId);
            
            const tx = await multisig.getTransaction(txId);
            expect(tx.canceled).to.be.true;
        });
        
        it("Should not cancel already executed transaction", async function () {
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            await multisig.connect(user).executeTransaction(txId);
            
            await expect(
                multisig.connect(owner).cancelTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "TransactionAlreadyExecuted");
        });
        
        it("Should not cancel already canceled transaction", async function () {
            await multisig.connect(owner).cancelTransaction(txId);
            
            await expect(
                multisig.connect(owner).cancelTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "TransactionCanceled");
        });
        
        it("Should only allow owner to cancel", async function () {
            await expect(
                multisig.connect(signer1).cancelTransaction(txId)
            ).to.be.revertedWithCustomError(multisig, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Complex Scenarios", function () {
        it("Should handle multiple transactions", async function () {
            const target = await testTarget.getAddress();
            
            // Create 3 transactions
            for (let i = 1; i <= 3; i++) {
                const data = testTarget.interface.encodeFunctionData("setValue", [i * 10]);
                await multisig.connect(owner).createTransaction(target, data, 0, 2);
            }
            
            // Sign and execute transactions out of order
            await multisig.connect(signer1).signTransaction(2);
            await multisig.connect(signer2).signTransaction(2);
            await multisig.connect(user).executeTransaction(2);
            
            expect(await testTarget.value()).to.equal(30);
            
            await multisig.connect(signer1).signTransaction(0);
            await multisig.connect(signer3).signTransaction(0);
            await multisig.connect(user).executeTransaction(0);
            
            expect(await testTarget.value()).to.equal(10);
        });
        
        it("Should handle signer removal during pending transaction", async function () {
            const target = await testTarget.getAddress();
            const data = testTarget.interface.encodeFunctionData("setValue", [99]);
            
            // Create transaction requiring 3 signatures
            await multisig.connect(owner).createTransaction(target, data, 0, 3);
            const txId = 0;
            
            // Two signers sign
            await multisig.connect(signer1).signTransaction(txId);
            await multisig.connect(signer2).signTransaction(txId);
            
            // Remove signer3
            await multisig.connect(owner).removeSigner(await signer3.getAddress());
            
            // Add new signer
            await multisig.connect(owner).addSigner(await signer4.getAddress());
            
            // New signer signs
            await multisig.connect(signer4).signTransaction(txId);
            
            // Execute should work
            await multisig.connect(user).executeTransaction(txId);
            expect(await testTarget.value()).to.equal(99);
        });
        
        it("Should handle different required signatures per transaction", async function () {
            const target = await testTarget.getAddress();
            
            // Add 4th signer
            await multisig.connect(owner).addSigner(await signer4.getAddress());
            
            // Transaction 1: Requires 2 signatures
            await multisig.connect(owner).createTransaction(
                target,
                testTarget.interface.encodeFunctionData("setValue", [100]),
                0,
                2
            );
            
            // Transaction 2: Requires 4 signatures
            await multisig.connect(owner).createTransaction(
                target,
                testTarget.interface.encodeFunctionData("setValue", [200]),
                0,
                4
            );
            
            // Execute transaction 1 with 2 signatures
            await multisig.connect(signer1).signTransaction(0);
            await multisig.connect(signer2).signTransaction(0);
            await multisig.connect(user).executeTransaction(0);
            
            expect(await testTarget.value()).to.equal(100);
            
            // Try to execute transaction 2 with only 2 signatures
            await multisig.connect(signer1).signTransaction(1);
            await multisig.connect(signer2).signTransaction(1);
            
            await expect(
                multisig.connect(user).executeTransaction(1)
            ).to.be.revertedWithCustomError(multisig, "InsufficientSignatures");
            
            // Add remaining signatures
            await multisig.connect(signer3).signTransaction(1);
            await multisig.connect(signer4).signTransaction(1);
            
            // Now it should execute
            await multisig.connect(user).executeTransaction(1);
            expect(await testTarget.value()).to.equal(200);
        });
    });
    
    describe("Helper Functions", function () {
        it("Should check if transfer is approved", async function () {
            // Small amounts don't need approval
            expect(await multisig.isApproved(
                await user.getAddress(),
                await treasury.getAddress(),
                ethers.parseUnits("500", 6)
            )).to.be.true;
            
            // Large amounts need approval
            expect(await multisig.isApproved(
                await user.getAddress(),
                await treasury.getAddress(),
                ethers.parseUnits("2000", 6)
            )).to.be.false;
        });
    });
});