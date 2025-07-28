const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("BatchProcessor", function () {
    let owner, processor, user1, user2, user3, treasury;
    let registry, omniCoin, privateOmniCoin, validator;
    let batchProcessor;
    
    // Constants
    const MAX_BATCH_SIZE = 100;
    const BATCH_FEE = ethers.parseUnits("0.1", 6); // 0.1 token per tx
    
    beforeEach(async function () {
        [owner, processor, user1, user2, user3, treasury] = await ethers.getSigners();
        
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
        
        // Deploy actual OmniCoinValidator
        const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
        validator = await OmniCoinValidator.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await validator.waitForDeployment();
        
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
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_VALIDATOR")),
            await validator.getAddress()
        );
        
        // Deploy BatchProcessor
        const BatchProcessor = await ethers.getContractFactory("BatchProcessor");
        batchProcessor = await BatchProcessor.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await batchProcessor.waitForDeployment();
        
        // Setup
        await batchProcessor.connect(owner).addProcessor(await processor.getAddress());
        
        // Fund users
        const fundAmount = ethers.parseUnits("1000", 6);
        await omniCoin.mint(await user1.getAddress(), fundAmount);
        await omniCoin.mint(await user2.getAddress(), fundAmount);
        await omniCoin.mint(await user3.getAddress(), fundAmount);
        
        // Approve batch processor
        await omniCoin.connect(user1).approve(await batchProcessor.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(user2).approve(await batchProcessor.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(user3).approve(await batchProcessor.getAddress(), ethers.MaxUint256);
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await batchProcessor.owner()).to.equal(await owner.getAddress());
            expect(await batchProcessor.maxBatchSize()).to.equal(MAX_BATCH_SIZE);
            expect(await batchProcessor.batchFee()).to.equal(BATCH_FEE);
        });
        
        it("Should update batch fee", async function () {
            const newFee = ethers.parseUnits("0.2", 6);
            
            await expect(batchProcessor.connect(owner).setBatchFee(newFee))
                .to.emit(batchProcessor, "BatchFeeUpdated")
                .withArgs(BATCH_FEE, newFee);
            
            expect(await batchProcessor.batchFee()).to.equal(newFee);
        });
        
        it("Should update max batch size", async function () {
            const newSize = 200;
            
            await expect(batchProcessor.connect(owner).setMaxBatchSize(newSize))
                .to.emit(batchProcessor, "MaxBatchSizeUpdated")
                .withArgs(MAX_BATCH_SIZE, newSize);
            
            expect(await batchProcessor.maxBatchSize()).to.equal(newSize);
        });
    });
    
    describe("Processor Management", function () {
        it("Should add processor", async function () {
            const newProcessor = await user3.getAddress();
            
            await expect(batchProcessor.connect(owner).addProcessor(newProcessor))
                .to.emit(batchProcessor, "ProcessorAdded")
                .withArgs(newProcessor);
            
            expect(await batchProcessor.isProcessor(newProcessor)).to.be.true;
        });
        
        it("Should remove processor", async function () {
            await expect(batchProcessor.connect(owner).removeProcessor(await processor.getAddress()))
                .to.emit(batchProcessor, "ProcessorRemoved")
                .withArgs(await processor.getAddress());
            
            expect(await batchProcessor.isProcessor(await processor.getAddress())).to.be.false;
        });
        
        it("Should only allow owner to manage processors", async function () {
            await expect(
                batchProcessor.connect(user1).addProcessor(await user2.getAddress())
            ).to.be.revertedWithCustomError(batchProcessor, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Token Transfer Batches", function () {
        it("Should process simple transfer batch", async function () {
            const recipients = [
                await user2.getAddress(),
                await user3.getAddress()
            ];
            const amounts = [
                ethers.parseUnits("50", 6),
                ethers.parseUnits("30", 6)
            ];
            
            const totalAmount = amounts[0] + amounts[1];
            const totalFee = BATCH_FEE * BigInt(recipients.length);
            
            const balanceBefore1 = await omniCoin.balanceOf(await user1.getAddress());
            
            await expect(
                batchProcessor.connect(user1).processBatchTransfer(
                    await omniCoin.getAddress(),
                    recipients,
                    amounts
                )
            ).to.emit(batchProcessor, "BatchProcessed")
                .withArgs(
                    await user1.getAddress(),
                    await omniCoin.getAddress(),
                    recipients.length,
                    totalAmount
                );
            
            // Check balances
            expect(await omniCoin.balanceOf(await user1.getAddress()))
                .to.equal(balanceBefore1 - totalAmount - totalFee);
            expect(await omniCoin.balanceOf(await user2.getAddress()))
                .to.equal(ethers.parseUnits("1050", 6)); // 1000 initial + 50 received
            expect(await omniCoin.balanceOf(await user3.getAddress()))
                .to.equal(ethers.parseUnits("1030", 6)); // 1000 initial + 30 received
        });
        
        it("Should handle batch with identical amounts", async function () {
            const recipients = [
                await user2.getAddress(),
                await user3.getAddress(),
                await treasury.getAddress()
            ];
            const amount = ethers.parseUnits("25", 6);
            
            await batchProcessor.connect(user1).processBatchTransferSameAmount(
                await omniCoin.getAddress(),
                recipients,
                amount
            );
            
            expect(await omniCoin.balanceOf(await user2.getAddress()))
                .to.equal(ethers.parseUnits("1025", 6));
            expect(await omniCoin.balanceOf(await user3.getAddress()))
                .to.equal(ethers.parseUnits("1025", 6));
            expect(await omniCoin.balanceOf(await treasury.getAddress()))
                .to.equal(amount);
        });
        
        it("Should fail if batch too large", async function () {
            const recipients = new Array(MAX_BATCH_SIZE + 1).fill(await user2.getAddress());
            const amounts = new Array(MAX_BATCH_SIZE + 1).fill(ethers.parseUnits("1", 6));
            
            await expect(
                batchProcessor.connect(user1).processBatchTransfer(
                    await omniCoin.getAddress(),
                    recipients,
                    amounts
                )
            ).to.be.revertedWithCustomError(batchProcessor, "BatchTooLarge");
        });
        
        it("Should fail if arrays mismatch", async function () {
            const recipients = [await user2.getAddress()];
            const amounts = [
                ethers.parseUnits("10", 6),
                ethers.parseUnits("20", 6)
            ];
            
            await expect(
                batchProcessor.connect(user1).processBatchTransfer(
                    await omniCoin.getAddress(),
                    recipients,
                    amounts
                )
            ).to.be.revertedWithCustomError(batchProcessor, "ArrayLengthMismatch");
        });
    });
    
    describe("Call Batches", function () {
        it("Should process batch of calls", async function () {
            const targets = [
                await omniCoin.getAddress(),
                await omniCoin.getAddress()
            ];
            
            const values = [0, 0];
            
            const calldatas = [
                omniCoin.interface.encodeFunctionData("transfer", [
                    await user2.getAddress(),
                    ethers.parseUnits("10", 6)
                ]),
                omniCoin.interface.encodeFunctionData("approve", [
                    await batchProcessor.getAddress(),
                    ethers.parseUnits("100", 6)
                ])
            ];
            
            await expect(
                batchProcessor.connect(processor).processBatchCall(
                    targets,
                    values,
                    calldatas
                )
            ).to.emit(batchProcessor, "BatchCallProcessed")
                .withArgs(await processor.getAddress(), targets.length);
        });
        
        it("Should only allow processor to execute batch calls", async function () {
            const targets = [await omniCoin.getAddress()];
            const values = [0];
            const calldatas = ["0x"];
            
            await expect(
                batchProcessor.connect(user1).processBatchCall(targets, values, calldatas)
            ).to.be.revertedWithCustomError(batchProcessor, "UnauthorizedProcessor");
        });
        
        it("Should handle failed calls in batch", async function () {
            const targets = [
                await omniCoin.getAddress(),
                ethers.ZeroAddress // This will fail
            ];
            
            const values = [0, 0];
            
            const calldatas = [
                omniCoin.interface.encodeFunctionData("transfer", [
                    await user2.getAddress(),
                    ethers.parseUnits("10", 6)
                ]),
                "0x12345678" // Invalid calldata
            ];
            
            const results = await batchProcessor.connect(processor).callStatic.processBatchCall(
                targets,
                values,
                calldatas
            );
            
            expect(results[0].success).to.be.true;
            expect(results[1].success).to.be.false;
        });
    });
    
    describe("Scheduled Batches", function () {
        it("Should schedule batch for future execution", async function () {
            const executeTime = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            await expect(
                batchProcessor.connect(user1).scheduleBatch(
                    await omniCoin.getAddress(),
                    recipients,
                    amounts,
                    executeTime
                )
            ).to.emit(batchProcessor, "BatchScheduled")
                .withArgs(
                    1, // batch ID
                    await user1.getAddress(),
                    executeTime
                );
            
            const batch = await batchProcessor.scheduledBatches(1);
            expect(batch.sender).to.equal(await user1.getAddress());
            expect(batch.token).to.equal(await omniCoin.getAddress());
            expect(batch.executeTime).to.equal(executeTime);
            expect(batch.executed).to.be.false;
        });
        
        it("Should execute scheduled batch after time", async function () {
            const executeTime = Math.floor(Date.now() / 1000) + 60; // 1 minute from now
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            await batchProcessor.connect(user1).scheduleBatch(
                await omniCoin.getAddress(),
                recipients,
                amounts,
                executeTime
            );
            
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [61]);
            await ethers.provider.send("evm_mine");
            
            await expect(batchProcessor.connect(processor).executeScheduledBatch(1))
                .to.emit(batchProcessor, "ScheduledBatchExecuted")
                .withArgs(1, await processor.getAddress());
            
            const batch = await batchProcessor.scheduledBatches(1);
            expect(batch.executed).to.be.true;
        });
        
        it("Should not execute batch before time", async function () {
            const executeTime = Math.floor(Date.now() / 1000) + 3600;
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            await batchProcessor.connect(user1).scheduleBatch(
                await omniCoin.getAddress(),
                recipients,
                amounts,
                executeTime
            );
            
            await expect(
                batchProcessor.connect(processor).executeScheduledBatch(1)
            ).to.be.revertedWithCustomError(batchProcessor, "BatchNotReady");
        });
        
        it("Should cancel scheduled batch", async function () {
            const executeTime = Math.floor(Date.now() / 1000) + 3600;
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            await batchProcessor.connect(user1).scheduleBatch(
                await omniCoin.getAddress(),
                recipients,
                amounts,
                executeTime
            );
            
            await expect(batchProcessor.connect(user1).cancelScheduledBatch(1))
                .to.emit(batchProcessor, "ScheduledBatchCancelled")
                .withArgs(1);
            
            const batch = await batchProcessor.scheduledBatches(1);
            expect(batch.cancelled).to.be.true;
        });
    });
    
    describe("Fee Collection", function () {
        it("Should collect fees to treasury", async function () {
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            const treasuryBalanceBefore = await omniCoin.balanceOf(await treasury.getAddress());
            
            await batchProcessor.connect(user1).processBatchTransfer(
                await omniCoin.getAddress(),
                recipients,
                amounts
            );
            
            const expectedFee = BATCH_FEE * BigInt(recipients.length);
            expect(await omniCoin.balanceOf(await treasury.getAddress()))
                .to.equal(treasuryBalanceBefore + expectedFee);
        });
        
        it("Should waive fees for whitelisted addresses", async function () {
            await batchProcessor.connect(owner).addToWhitelist(await user1.getAddress());
            
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            const balanceBefore = await omniCoin.balanceOf(await user1.getAddress());
            
            await batchProcessor.connect(user1).processBatchTransfer(
                await omniCoin.getAddress(),
                recipients,
                amounts
            );
            
            // Should only deduct transfer amount, not fees
            expect(await omniCoin.balanceOf(await user1.getAddress()))
                .to.equal(balanceBefore - amounts[0]);
        });
    });
    
    describe("Emergency Functions", function () {
        it("Should pause batch processing", async function () {
            await batchProcessor.connect(owner).pause();
            
            const recipients = [await user2.getAddress()];
            const amounts = [ethers.parseUnits("50", 6)];
            
            await expect(
                batchProcessor.connect(user1).processBatchTransfer(
                    await omniCoin.getAddress(),
                    recipients,
                    amounts
                )
            ).to.be.revertedWithCustomError(batchProcessor, "EnforcedPause");
        });
        
        it("Should recover stuck tokens", async function () {
            // Send tokens directly to contract
            const stuckAmount = ethers.parseUnits("100", 6);
            await omniCoin.mint(await batchProcessor.getAddress(), stuckAmount);
            
            await batchProcessor.connect(owner).recoverToken(
                await omniCoin.getAddress(),
                stuckAmount
            );
            
            expect(await omniCoin.balanceOf(await owner.getAddress()))
                .to.equal(stuckAmount);
        });
    });
});