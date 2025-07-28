const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinGarbledCircuit", function () {
    let owner, user1, user2, treasury;
    let garbledCircuit;
    let registry, omniCoin;
    
    // Constants
    const DEFAULT_MAX_CIRCUIT_SIZE = 1024 * 1024; // 1MB
    const DEFAULT_MAX_INPUT_SIZE = 1024; // 1KB
    const DEFAULT_MAX_OUTPUT_SIZE = 1024; // 1KB
    
    beforeEach(async function () {
        [owner, user1, user2, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
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
        
        // Deploy OmniCoinGarbledCircuit
        const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
        garbledCircuit = await OmniCoinGarbledCircuit.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await garbledCircuit.waitForDeployment();
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await garbledCircuit.owner()).to.equal(await owner.getAddress());
            expect(await garbledCircuit.circuitCount()).to.equal(0);
            expect(await garbledCircuit.maxCircuitSize()).to.equal(DEFAULT_MAX_CIRCUIT_SIZE);
            expect(await garbledCircuit.maxInputSize()).to.equal(DEFAULT_MAX_INPUT_SIZE);
            expect(await garbledCircuit.maxOutputSize()).to.equal(DEFAULT_MAX_OUTPUT_SIZE);
        });
        
        it("Should update maximum circuit size", async function () {
            const newSize = 2 * 1024 * 1024; // 2MB
            
            await expect(garbledCircuit.connect(owner).setMaxCircuitSize(newSize))
                .to.emit(garbledCircuit, "MaxCircuitSizeUpdated")
                .withArgs(DEFAULT_MAX_CIRCUIT_SIZE, newSize);
            
            expect(await garbledCircuit.maxCircuitSize()).to.equal(newSize);
        });
        
        it("Should update maximum input size", async function () {
            const newSize = 2048; // 2KB
            
            await expect(garbledCircuit.connect(owner).setMaxInputSize(newSize))
                .to.emit(garbledCircuit, "MaxInputSizeUpdated")
                .withArgs(DEFAULT_MAX_INPUT_SIZE, newSize);
            
            expect(await garbledCircuit.maxInputSize()).to.equal(newSize);
        });
        
        it("Should update maximum output size", async function () {
            const newSize = 2048; // 2KB
            
            await expect(garbledCircuit.connect(owner).setMaxOutputSize(newSize))
                .to.emit(garbledCircuit, "MaxOutputSizeUpdated")
                .withArgs(DEFAULT_MAX_OUTPUT_SIZE, newSize);
            
            expect(await garbledCircuit.maxOutputSize()).to.equal(newSize);
        });
        
        it("Should only allow owner to update sizes", async function () {
            await expect(
                garbledCircuit.connect(user1).setMaxCircuitSize(2048)
            ).to.be.revertedWithCustomError(garbledCircuit, "OwnableUnauthorizedAccount");
            
            await expect(
                garbledCircuit.connect(user1).setMaxInputSize(2048)
            ).to.be.revertedWithCustomError(garbledCircuit, "OwnableUnauthorizedAccount");
            
            await expect(
                garbledCircuit.connect(user1).setMaxOutputSize(2048)
            ).to.be.revertedWithCustomError(garbledCircuit, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Circuit Creation", function () {
        it("Should create a basic circuit", async function () {
            // Create circuit data with metadata
            const inputSize = 32;
            const outputSize = 32;
            const circuitData = ethers.concat([
                ethers.toBeHex(inputSize, 8),  // Input size (8 bytes)
                ethers.toBeHex(outputSize, 8), // Output size (8 bytes)
                ethers.randomBytes(100)         // Circuit logic
            ]);
            
            await expect(
                garbledCircuit.connect(owner).createCircuit(
                    await owner.getAddress(),
                    circuitData
                )
            ).to.emit(garbledCircuit, "CircuitCreated")
                .withArgs(1, inputSize, outputSize);
            
            expect(await garbledCircuit.circuitCount()).to.equal(1);
            
            // Verify circuit data
            const circuit = await garbledCircuit.getCircuit(1);
            expect(circuit.circuit).to.equal(ethers.hexlify(circuitData));
            expect(circuit.inputSize).to.equal(inputSize);
            expect(circuit.outputSize).to.equal(outputSize);
            expect(circuit.isActive).to.be.true;
        });
        
        it("Should create circuit with custom sizes", async function () {
            const inputSize = 64;
            const outputSize = 128;
            const circuitData = ethers.concat([
                ethers.toBeHex(inputSize, 8),
                ethers.toBeHex(outputSize, 8),
                ethers.randomBytes(200)
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuitData
            );
            
            const circuit = await garbledCircuit.getCircuit(1);
            expect(circuit.inputSize).to.equal(inputSize);
            expect(circuit.outputSize).to.equal(outputSize);
        });
        
        it("Should reject circuit that exceeds size limit", async function () {
            const oversizedCircuit = ethers.randomBytes(DEFAULT_MAX_CIRCUIT_SIZE + 1);
            
            await expect(
                garbledCircuit.connect(owner).createCircuit(
                    await owner.getAddress(),
                    oversizedCircuit
                )
            ).to.be.revertedWithCustomError(garbledCircuit, "CircuitTooLarge");
        });
        
        it("Should only allow owner to create circuits", async function () {
            const circuitData = ethers.randomBytes(100);
            
            await expect(
                garbledCircuit.connect(user1).createCircuit(
                    await user1.getAddress(),
                    circuitData
                )
            ).to.be.revertedWithCustomError(garbledCircuit, "OwnableUnauthorizedAccount");
        });
        
        it("Should handle minimal circuit data", async function () {
            // Circuit with less than 16 bytes (no size metadata)
            const minimalCircuit = ethers.randomBytes(10);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                minimalCircuit
            );
            
            const circuit = await garbledCircuit.getCircuit(1);
            expect(circuit.inputSize).to.equal(32); // Default
            expect(circuit.outputSize).to.equal(32); // Default
        });
    });
    
    describe("Circuit Deactivation", function () {
        let circuitId;
        
        beforeEach(async function () {
            const circuitData = ethers.concat([
                ethers.toBeHex(32, 8),
                ethers.toBeHex(32, 8),
                ethers.randomBytes(100)
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuitData
            );
            circuitId = 1;
        });
        
        it("Should deactivate active circuit", async function () {
            await expect(garbledCircuit.connect(owner).deactivateCircuit(circuitId))
                .to.emit(garbledCircuit, "CircuitDeactivated")
                .withArgs(circuitId);
            
            const circuit = await garbledCircuit.getCircuit(circuitId);
            expect(circuit.isActive).to.be.false;
        });
        
        it("Should reject deactivating already inactive circuit", async function () {
            await garbledCircuit.connect(owner).deactivateCircuit(circuitId);
            
            await expect(
                garbledCircuit.connect(owner).deactivateCircuit(circuitId)
            ).to.be.revertedWithCustomError(garbledCircuit, "CircuitNotActive");
        });
        
        it("Should only allow owner to deactivate", async function () {
            await expect(
                garbledCircuit.connect(user1).deactivateCircuit(circuitId)
            ).to.be.revertedWithCustomError(garbledCircuit, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Circuit Evaluation", function () {
        let circuitId;
        const inputSize = 32;
        const outputSize = 32;
        
        beforeEach(async function () {
            const circuitData = ethers.concat([
                ethers.toBeHex(inputSize, 8),
                ethers.toBeHex(outputSize, 8),
                ethers.randomBytes(100)
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuitData
            );
            circuitId = 1;
        });
        
        it("Should evaluate circuit with valid input", async function () {
            const input = ethers.randomBytes(inputSize);
            
            await expect(garbledCircuit.connect(user1).evaluateCircuit(circuitId, input))
                .to.emit(garbledCircuit, "CircuitEvaluated");
            
            expect(await garbledCircuit.getEvaluationCount(circuitId)).to.equal(1);
            
            // Check evaluation details
            const evaluation = await garbledCircuit.getEvaluation(circuitId, 0);
            expect(evaluation.input).to.equal(ethers.hexlify(input));
            expect(evaluation.output).to.have.lengthOf(2 + outputSize * 2); // "0x" + hex chars
            expect(evaluation.timestamp).to.be.gt(0);
        });
        
        it("Should handle multiple evaluations", async function () {
            const evaluationCount = 5;
            
            for (let i = 0; i < evaluationCount; i++) {
                const input = ethers.randomBytes(inputSize);
                await garbledCircuit.connect(user1).evaluateCircuit(circuitId, input);
            }
            
            expect(await garbledCircuit.getEvaluationCount(circuitId)).to.equal(evaluationCount);
        });
        
        it("Should reject evaluation of inactive circuit", async function () {
            await garbledCircuit.connect(owner).deactivateCircuit(circuitId);
            
            const input = ethers.randomBytes(inputSize);
            await expect(
                garbledCircuit.connect(user1).evaluateCircuit(circuitId, input)
            ).to.be.revertedWithCustomError(garbledCircuit, "CircuitNotActive");
        });
        
        it("Should reject input that exceeds size limit", async function () {
            const oversizedInput = ethers.randomBytes(DEFAULT_MAX_INPUT_SIZE + 1);
            
            await expect(
                garbledCircuit.connect(user1).evaluateCircuit(circuitId, oversizedInput)
            ).to.be.revertedWithCustomError(garbledCircuit, "InputTooLarge");
        });
        
        it("Should reject input with incorrect size", async function () {
            const wrongSizeInput = ethers.randomBytes(inputSize + 1);
            
            await expect(
                garbledCircuit.connect(user1).evaluateCircuit(circuitId, wrongSizeInput)
            ).to.be.revertedWithCustomError(garbledCircuit, "InvalidInputSize");
        });
        
        it("Should produce deterministic output for same input", async function () {
            const input = ethers.randomBytes(inputSize);
            
            // Evaluate twice with same input
            await garbledCircuit.connect(user1).evaluateCircuit(circuitId, input);
            await garbledCircuit.connect(user1).evaluateCircuit(circuitId, input);
            
            const eval1 = await garbledCircuit.getEvaluation(circuitId, 0);
            const eval2 = await garbledCircuit.getEvaluation(circuitId, 1);
            
            expect(eval1.output).to.equal(eval2.output);
        });
    });
    
    describe("Complex Scenarios", function () {
        it("Should handle multiple circuits", async function () {
            const circuitCount = 3;
            const circuitIds = [];
            
            // Create multiple circuits with different sizes
            for (let i = 0; i < circuitCount; i++) {
                const inputSize = 32 + i * 16;
                const outputSize = 32 + i * 8;
                const circuitData = ethers.concat([
                    ethers.toBeHex(inputSize, 8),
                    ethers.toBeHex(outputSize, 8),
                    ethers.randomBytes(100 + i * 50)
                ]);
                
                await garbledCircuit.connect(owner).createCircuit(
                    await owner.getAddress(),
                    circuitData
                );
                circuitIds.push(i + 1);
            }
            
            expect(await garbledCircuit.circuitCount()).to.equal(circuitCount);
            
            // Evaluate each circuit
            for (let i = 0; i < circuitCount; i++) {
                const circuit = await garbledCircuit.getCircuit(circuitIds[i]);
                const input = ethers.randomBytes(Number(circuit.inputSize));
                
                await garbledCircuit.connect(user1).evaluateCircuit(circuitIds[i], input);
            }
        });
        
        it("Should track evaluation history per circuit", async function () {
            // Create two circuits
            const circuit1Data = ethers.concat([
                ethers.toBeHex(32, 8),
                ethers.toBeHex(32, 8),
                ethers.randomBytes(100)
            ]);
            const circuit2Data = ethers.concat([
                ethers.toBeHex(64, 8),
                ethers.toBeHex(64, 8),
                ethers.randomBytes(200)
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuit1Data
            );
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuit2Data
            );
            
            // Evaluate circuit 1 three times
            for (let i = 0; i < 3; i++) {
                await garbledCircuit.connect(user1).evaluateCircuit(1, ethers.randomBytes(32));
            }
            
            // Evaluate circuit 2 twice
            for (let i = 0; i < 2; i++) {
                await garbledCircuit.connect(user2).evaluateCircuit(2, ethers.randomBytes(64));
            }
            
            expect(await garbledCircuit.getEvaluationCount(1)).to.equal(3);
            expect(await garbledCircuit.getEvaluationCount(2)).to.equal(2);
        });
        
        it("Should handle edge case circuit sizes", async function () {
            // Maximum allowed circuit
            const maxCircuit = ethers.concat([
                ethers.toBeHex(32, 8),
                ethers.toBeHex(32, 8),
                ethers.randomBytes(DEFAULT_MAX_CIRCUIT_SIZE - 16)
            ]);
            
            await expect(
                garbledCircuit.connect(owner).createCircuit(
                    await owner.getAddress(),
                    maxCircuit
                )
            ).to.not.be.reverted;
            
            // Maximum allowed input
            const inputSize = DEFAULT_MAX_INPUT_SIZE;
            const largeInputCircuit = ethers.concat([
                ethers.toBeHex(inputSize, 8),
                ethers.toBeHex(32, 8),
                ethers.randomBytes(100)
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                largeInputCircuit
            );
            
            const maxInput = ethers.randomBytes(inputSize);
            await expect(
                garbledCircuit.connect(user1).evaluateCircuit(2, maxInput)
            ).to.not.be.reverted;
        });
    });
    
    describe("View Functions", function () {
        it("Should return correct circuit details", async function () {
            const inputSize = 48;
            const outputSize = 96;
            const circuitLogic = ethers.randomBytes(200);
            const circuitData = ethers.concat([
                ethers.toBeHex(inputSize, 8),
                ethers.toBeHex(outputSize, 8),
                circuitLogic
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuitData
            );
            
            const circuit = await garbledCircuit.getCircuit(1);
            expect(circuit.circuit).to.equal(ethers.hexlify(circuitData));
            expect(circuit.inputSize).to.equal(inputSize);
            expect(circuit.outputSize).to.equal(outputSize);
            expect(circuit.isActive).to.be.true;
            expect(circuit.inputLabels).to.have.lengthOf(2 + inputSize * 2); // Account for 0x prefix
            expect(circuit.outputLabels).to.have.lengthOf(2 + outputSize * 2);
        });
        
        it("Should return correct evaluation details", async function () {
            const circuitData = ethers.concat([
                ethers.toBeHex(32, 8),
                ethers.toBeHex(32, 8),
                ethers.randomBytes(100)
            ]);
            
            await garbledCircuit.connect(owner).createCircuit(
                await owner.getAddress(),
                circuitData
            );
            
            const input = ethers.randomBytes(32);
            const timestampBefore = await ethers.provider.getBlock().then(b => b.timestamp);
            
            await garbledCircuit.connect(user1).evaluateCircuit(1, input);
            
            const timestampAfter = await ethers.provider.getBlock().then(b => b.timestamp);
            const evaluation = await garbledCircuit.getEvaluation(1, 0);
            
            expect(evaluation.input).to.equal(ethers.hexlify(input));
            expect(evaluation.timestamp).to.be.gte(timestampBefore);
            expect(evaluation.timestamp).to.be.lte(timestampAfter);
        });
    });
});