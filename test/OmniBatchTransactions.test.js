const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniBatchTransactions", function () {
    let owner, user1, user2, user3, executor, treasury;
    let batchProcessor;
    let registry, omniCoin, privateOmniCoin;
    let bridge, listingNFT, escrow, privacy, validator, privacyFeeManager, garbledCircuit;
    
    // Constants
    const DEFAULT_MAX_BATCH_SIZE = 50;
    const DEFAULT_MAX_GAS_PER_OPERATION = 500000;
    
    // Transaction types
    const TransactionType = {
        TRANSFER: 0,
        APPROVE: 1,
        NFT_MINT: 2,
        NFT_TRANSFER: 3,
        ESCROW_CREATE: 4,
        ESCROW_RELEASE: 5,
        BRIDGE_TRANSFER: 6,
        PRIVACY_DEPOSIT: 7,
        PRIVACY_WITHDRAW: 8,
        STAKE: 9,
        UNSTAKE: 10
    };
    
    beforeEach(async function () {
        [owner, user1, user2, user3, executor, treasury] = await ethers.getSigners();
        
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
        
        // Deploy actual ListingNFT
        const ListingNFT = await ethers.getContractFactory("ListingNFT");
        listingNFT = await ListingNFT.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await listingNFT.waitForDeployment();
        
        // Deploy actual OmniCoinEscrow
        const OmniCoinEscrow = await ethers.getContractFactory("OmniCoinEscrow");
        escrow = await OmniCoinEscrow.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await escrow.waitForDeployment();
        
        // Deploy actual PrivacyFeeManager (needed for bridge)
        const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
        privacyFeeManager = await PrivacyFeeManager.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await privacyFeeManager.waitForDeployment();
        
        // Deploy actual OmniCoinBridge
        const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
        bridge = await OmniCoinBridge.deploy(
            await registry.getAddress(),
            await omniCoin.getAddress(),
            await owner.getAddress(),
            await privacyFeeManager.getAddress()
        );
        await bridge.waitForDeployment();
        
        // Deploy actual OmniCoinGarbledCircuit (needed for privacy)
        const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
        garbledCircuit = await OmniCoinGarbledCircuit.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await garbledCircuit.waitForDeployment();
        
        // Deploy actual OmniCoinPrivacy
        const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
        privacy = await OmniCoinPrivacy.deploy(
            await registry.getAddress(),
            await privateOmniCoin.getAddress()
        );
        await privacy.waitForDeployment();
        
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
            ethers.keccak256(ethers.toUtf8Bytes("LISTING_NFT")),
            await listingNFT.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("ESCROW")),
            await escrow.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_BRIDGE")),
            await bridge.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_PRIVACY")),
            await privacy.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN_VALIDATOR")),
            await validator.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("GARBLED_CIRCUIT")),
            await garbledCircuit.getAddress()
        );
        
        // Deploy OmniBatchTransactions
        const OmniBatchTransactions = await ethers.getContractFactory("OmniBatchTransactions");
        batchProcessor = await OmniBatchTransactions.deploy();
        await batchProcessor.waitForDeployment();
        
        // Initialize batch processor
        await batchProcessor.initialize(
            await registry.getAddress(),
            await owner.getAddress()
        );
        
        // Fund users and batch processor
        await omniCoin.mint(await user1.getAddress(), ethers.parseUnits("10000", 6));
        await omniCoin.mint(await batchProcessor.getAddress(), ethers.parseUnits("5000", 6));
        await privateOmniCoin.mint(await batchProcessor.getAddress(), ethers.parseUnits("5000", 6));
        
        // Approve batch processor
        await omniCoin.connect(user1).approve(
            await batchProcessor.getAddress(),
            ethers.MaxUint256
        );
    });
    
    describe("Deployment and Initialization", function () {
        it("Should set correct initial values", async function () {
            expect(await batchProcessor.owner()).to.equal(await owner.getAddress());
            expect(await batchProcessor.batchCounter()).to.equal(0);
            expect(await batchProcessor.maxBatchSize()).to.equal(DEFAULT_MAX_BATCH_SIZE);
            expect(await batchProcessor.maxGasPerOperation()).to.equal(DEFAULT_MAX_GAS_PER_OPERATION);
            expect(await batchProcessor.registry()).to.equal(await registry.getAddress());
        });
        
        it("Should not allow reinitialization", async function () {
            await expect(
                batchProcessor.initialize(
                    await registry.getAddress(),
                    await owner.getAddress()
                )
            ).to.be.revertedWith("Initializable: contract is already initialized");
        });
    });
    
    describe("Batch Execution", function () {
        it("Should execute simple transfer batch", async function () {
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.TRANSFER,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256"],
                    [await user2.getAddress(), ethers.parseUnits("100", 6)]
                )
            }];
            
            const balanceBefore = await omniCoin.balanceOf(await user2.getAddress());
            
            const tx = await batchProcessor.executeBatch(operations);
            const receipt = await tx.wait();
            
            // Check events
            const startEvent = receipt.logs.find(
                log => log.fragment && log.fragment.name === "BatchExecutionStarted"
            );
            expect(startEvent).to.not.be.undefined;
            
            const completeEvent = receipt.logs.find(
                log => log.fragment && log.fragment.name === "BatchExecutionCompleted"
            );
            expect(completeEvent).to.not.be.undefined;
            
            const balanceAfter = await omniCoin.balanceOf(await user2.getAddress());
            expect(balanceAfter - balanceBefore).to.equal(ethers.parseUnits("100", 6));
            
            // Check batch execution details
            const batchExecution = await batchProcessor.getBatchExecution(1);
            expect(batchExecution.completed).to.be.true;
            expect(batchExecution.successCount).to.equal(1);
            expect(batchExecution.operationCount).to.equal(1);
        });
        
        it("Should execute multiple operations in batch", async function () {
            const operations = [
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user2.getAddress(), ethers.parseUnits("100", 6)]
                    )
                },
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user3.getAddress(), ethers.parseUnits("200", 6)]
                    )
                }
            ];
            
            await batchProcessor.executeBatch(operations);
            
            expect(await omniCoin.balanceOf(await user2.getAddress())).to.equal(
                ethers.parseUnits("100", 6)
            );
            expect(await omniCoin.balanceOf(await user3.getAddress())).to.equal(
                ethers.parseUnits("200", 6)
            );
        });
        
        it("Should handle critical operation failure", async function () {
            const operations = [
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: true,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user2.getAddress(), ethers.parseUnits("100000", 6)] // More than available
                    )
                },
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user3.getAddress(), ethers.parseUnits("100", 6)]
                    )
                }
            ];
            
            await batchProcessor.executeBatch(operations);
            
            // Second operation should not execute due to critical failure
            expect(await omniCoin.balanceOf(await user3.getAddress())).to.equal(0);
            
            const batchExecution = await batchProcessor.getBatchExecution(1);
            expect(batchExecution.successCount).to.equal(0);
        });
        
        it("Should continue after non-critical failure", async function () {
            const operations = [
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false, // Non-critical
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user2.getAddress(), ethers.parseUnits("100000", 6)] // More than available
                    )
                },
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user3.getAddress(), ethers.parseUnits("100", 6)]
                    )
                }
            ];
            
            await batchProcessor.executeBatch(operations);
            
            // Second operation should execute despite first failure
            expect(await omniCoin.balanceOf(await user3.getAddress())).to.equal(
                ethers.parseUnits("100", 6)
            );
            
            const batchExecution = await batchProcessor.getBatchExecution(1);
            expect(batchExecution.successCount).to.equal(1);
        });
        
        it("Should reject empty batch", async function () {
            await expect(
                batchProcessor.executeBatch([])
            ).to.be.revertedWithCustomError(batchProcessor, "EmptyBatch");
        });
        
        it("Should reject batch exceeding size limit", async function () {
            const operations = [];
            for (let i = 0; i < DEFAULT_MAX_BATCH_SIZE + 1; i++) {
                operations.push({
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user2.getAddress(), ethers.parseUnits("1", 6)]
                    )
                });
            }
            
            await expect(
                batchProcessor.executeBatch(operations)
            ).to.be.revertedWithCustomError(batchProcessor, "BatchTooLarge");
        });
    });
    
    describe("Different Operation Types", function () {
        it("Should execute approval operation", async function () {
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.APPROVE,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256"],
                    [await user2.getAddress(), ethers.parseUnits("1000", 6)]
                )
            }];
            
            await batchProcessor.executeBatch(operations);
            
            // Check approval was set
            expect(await omniCoin.allowance(
                await batchProcessor.getAddress(),
                await user2.getAddress()
            )).to.equal(ethers.parseUnits("1000", 6));
        });
        
        it("Should execute privacy deposit (bridge to private)", async function () {
            const amount = ethers.parseUnits("500", 6);
            
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.PRIVACY_DEPOSIT,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [amount])
            }];
            
            await batchProcessor.executeBatch(operations);
            
            // Check bridge was called
            expect(await bridge.lastConvertedAmount()).to.equal(amount);
            expect(await bridge.lastToPrivate()).to.be.true;
        });
        
        it("Should execute privacy withdraw (bridge to public)", async function () {
            const amount = ethers.parseUnits("300", 6);
            
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.PRIVACY_WITHDRAW,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [amount])
            }];
            
            await batchProcessor.executeBatch(operations);
            
            // Check bridge was called
            expect(await bridge.lastConvertedAmount()).to.equal(amount);
            expect(await bridge.lastToPrivate()).to.be.false;
        });
        
        it("Should reject stake operations", async function () {
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.STAKE,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [ethers.parseUnits("100", 6)])
            }];
            
            await batchProcessor.executeBatch(operations);
            
            const batchExecution = await batchProcessor.getBatchExecution(1);
            expect(batchExecution.successCount).to.equal(0);
        });
        
        it("Should execute NFT mint via direct call", async function () {
            const operations = [{
                target: await listingNFT.getAddress(),
                opType: TransactionType.NFT_MINT,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: listingNFT.interface.encodeFunctionData("mint", [
                    await user2.getAddress(),
                    "https://example.com/nft/1"
                ])
            }];
            
            await batchProcessor.executeBatch(operations);
            
            // Check NFT was minted
            const tokenId = await listingNFT.currentTokenId();
            expect(await listingNFT.ownerOf(tokenId)).to.equal(await user2.getAddress());
        });
    });
    
    describe("Privacy-enabled Operations", function () {
        it("Should execute transfer with privacy flag", async function () {
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.TRANSFER,
                critical: false,
                usePrivacy: true, // Use private token
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256"],
                    [await user2.getAddress(), ethers.parseUnits("50", 6)]
                )
            }];
            
            await batchProcessor.executeBatch(operations);
            
            // Check private token balance
            expect(await privateOmniCoin.balanceOf(await user2.getAddress())).to.equal(
                ethers.parseUnits("50", 6)
            );
        });
        
        it("Should execute approval with privacy flag", async function () {
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.APPROVE,
                critical: false,
                usePrivacy: true, // Use private token
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256"],
                    [await user2.getAddress(), ethers.parseUnits("500", 6)]
                )
            }];
            
            await batchProcessor.executeBatch(operations);
            
            // Check private token approval
            expect(await privateOmniCoin.allowance(
                await batchProcessor.getAddress(),
                await user2.getAddress()
            )).to.equal(ethers.parseUnits("500", 6));
        });
    });
    
    describe("Batch Creation Helpers", function () {
        it("Should create transfer batch", async function () {
            const recipients = [
                await user1.getAddress(),
                await user2.getAddress(),
                await user3.getAddress()
            ];
            const amounts = [
                ethers.parseUnits("100", 6),
                ethers.parseUnits("200", 6),
                ethers.parseUnits("300", 6)
            ];
            
            const operations = await batchProcessor.createTransferBatch(recipients, amounts);
            
            expect(operations.length).to.equal(3);
            for (let i = 0; i < operations.length; i++) {
                expect(operations[i].opType).to.equal(TransactionType.TRANSFER);
                expect(operations[i].critical).to.be.false;
                expect(operations[i].usePrivacy).to.be.false;
                
                const [recipient, amount] = ethers.AbiCoder.defaultAbiCoder().decode(
                    ["address", "uint256"],
                    operations[i].data
                );
                expect(recipient).to.equal(recipients[i]);
                expect(amount).to.equal(amounts[i]);
            }
        });
        
        it("Should create NFT batch", async function () {
            const nftContract = await listingNFT.getAddress();
            const recipients = [
                await user1.getAddress(),
                await user2.getAddress()
            ];
            const tokenURIs = [
                "https://example.com/nft/1",
                "https://example.com/nft/2"
            ];
            
            const operations = await batchProcessor.createNFTBatch(
                nftContract,
                recipients,
                tokenURIs
            );
            
            expect(operations.length).to.equal(2);
            for (let i = 0; i < operations.length; i++) {
                expect(operations[i].opType).to.equal(TransactionType.NFT_MINT);
                expect(operations[i].target).to.equal(nftContract);
                expect(operations[i].critical).to.be.false;
            }
        });
        
        it("Should reject mismatched array lengths", async function () {
            const recipients = [await user1.getAddress()];
            const amounts = [
                ethers.parseUnits("100", 6),
                ethers.parseUnits("200", 6)
            ];
            
            await expect(
                batchProcessor.createTransferBatch(recipients, amounts)
            ).to.be.revertedWithCustomError(batchProcessor, "ArrayLengthMismatch");
        });
        
        it("Should reject too many transfers", async function () {
            const recipients = [];
            const amounts = [];
            
            for (let i = 0; i < DEFAULT_MAX_BATCH_SIZE + 1; i++) {
                recipients.push(await user1.getAddress());
                amounts.push(ethers.parseUnits("1", 6));
            }
            
            await expect(
                batchProcessor.createTransferBatch(recipients, amounts)
            ).to.be.revertedWithCustomError(batchProcessor, "TooManyTransfers");
        });
    });
    
    describe("Gas Estimation", function () {
        it("Should estimate gas for operations", async function () {
            const operations = [
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: "0x"
                },
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.APPROVE,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: "0x"
                },
                {
                    target: ethers.ZeroAddress,
                    opType: TransactionType.NFT_MINT,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: "0x"
                }
            ];
            
            const gasEstimate = await batchProcessor.estimateBatchGas(operations);
            
            // Base gas + transfer + approve + NFT mint
            const expectedGas = 21000 + 65000 + 46000 + 150000;
            expect(gasEstimate).to.equal(expectedGas);
        });
    });
    
    describe("Executor Management", function () {
        it("Should authorize executor", async function () {
            await expect(batchProcessor.connect(owner).authorizeExecutor(await executor.getAddress()))
                .to.emit(batchProcessor, "ExecutorAuthorized")
                .withArgs(await executor.getAddress());
            
            expect(await batchProcessor.authorizedExecutors(await executor.getAddress())).to.be.true;
        });
        
        it("Should deauthorize executor", async function () {
            await batchProcessor.connect(owner).authorizeExecutor(await executor.getAddress());
            
            await expect(batchProcessor.connect(owner).deauthorizeExecutor(await executor.getAddress()))
                .to.emit(batchProcessor, "ExecutorDeauthorized")
                .withArgs(await executor.getAddress());
            
            expect(await batchProcessor.authorizedExecutors(await executor.getAddress())).to.be.false;
        });
        
        it("Should only allow owner to manage executors", async function () {
            await expect(
                batchProcessor.connect(user1).authorizeExecutor(await executor.getAddress())
            ).to.be.revertedWithCustomError(batchProcessor, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Admin Functions", function () {
        it("Should update max batch size", async function () {
            const newSize = 75;
            
            await expect(batchProcessor.connect(owner).updateMaxBatchSize(newSize))
                .to.emit(batchProcessor, "MaxBatchSizeUpdated")
                .withArgs(newSize);
            
            expect(await batchProcessor.maxBatchSize()).to.equal(newSize);
        });
        
        it("Should reject invalid batch size", async function () {
            await expect(
                batchProcessor.connect(owner).updateMaxBatchSize(0)
            ).to.be.revertedWithCustomError(batchProcessor, "InvalidMaxBatchSize");
            
            await expect(
                batchProcessor.connect(owner).updateMaxBatchSize(101)
            ).to.be.revertedWithCustomError(batchProcessor, "InvalidMaxBatchSize");
        });
        
        it("Should update max gas per operation", async function () {
            const newGas = 750000;
            
            await expect(batchProcessor.connect(owner).updateMaxGasPerOperation(newGas))
                .to.emit(batchProcessor, "MaxGasPerOperationUpdated")
                .withArgs(newGas);
            
            expect(await batchProcessor.maxGasPerOperation()).to.equal(newGas);
        });
        
        it("Should reject invalid gas limit", async function () {
            await expect(
                batchProcessor.connect(owner).updateMaxGasPerOperation(50000)
            ).to.be.revertedWithCustomError(batchProcessor, "InvalidMaxGasPerOperation");
            
            await expect(
                batchProcessor.connect(owner).updateMaxGasPerOperation(1500000)
            ).to.be.revertedWithCustomError(batchProcessor, "InvalidMaxGasPerOperation");
        });
    });
    
    describe("Pausable", function () {
        it("Should pause batch execution", async function () {
            await batchProcessor.connect(owner).emergencyPause();
            
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.TRANSFER,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256"],
                    [await user2.getAddress(), ethers.parseUnits("100", 6)]
                )
            }];
            
            await expect(
                batchProcessor.executeBatch(operations)
            ).to.be.revertedWith("Pausable: paused");
        });
        
        it("Should unpause batch execution", async function () {
            await batchProcessor.connect(owner).emergencyPause();
            await batchProcessor.connect(owner).emergencyUnpause();
            
            const operations = [{
                target: ethers.ZeroAddress,
                opType: TransactionType.TRANSFER,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256"],
                    [await user2.getAddress(), ethers.parseUnits("100", 6)]
                )
            }];
            
            await expect(batchProcessor.executeBatch(operations)).to.not.be.reverted;
        });
    });
    
    describe("View Functions", function () {
        it("Should track user batch history", async function () {
            // Execute multiple batches
            for (let i = 0; i < 3; i++) {
                const operations = [{
                    target: ethers.ZeroAddress,
                    opType: TransactionType.TRANSFER,
                    critical: false,
                    usePrivacy: false,
                    gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                    value: 0,
                    data: ethers.AbiCoder.defaultAbiCoder().encode(
                        ["address", "uint256"],
                        [await user2.getAddress(), ethers.parseUnits("10", 6)]
                    )
                }];
                
                await batchProcessor.connect(user1).executeBatch(operations);
            }
            
            const userBatches = await batchProcessor.getUserBatches(await user1.getAddress());
            expect(userBatches.length).to.equal(3);
            expect(userBatches).to.deep.equal([1, 2, 3]);
        });
        
        it("Should handle internal-only function protection", async function () {
            const operation = {
                target: ethers.ZeroAddress,
                opType: TransactionType.TRANSFER,
                critical: false,
                usePrivacy: false,
                gasLimit: DEFAULT_MAX_GAS_PER_OPERATION,
                value: 0,
                data: "0x"
            };
            
            await expect(
                batchProcessor._performOperation(operation)
            ).to.be.revertedWithCustomError(batchProcessor, "InternalCallOnly");
        });
    });
});