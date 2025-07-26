const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinCore", function () {
    // Constants
    const INITIAL_SUPPLY = ethers.parseUnits("100000000", 6); // 100M tokens with 6 decimals
    const MAX_SUPPLY = ethers.parseUnits("1000000000", 6); // 1B tokens max supply
    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
    const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
    const VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("VALIDATOR_ROLE"));
    const BRIDGE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BRIDGE_ROLE"));

    async function deployOmniCoinCoreFixture() {
        const [admin, user1, user2, validator1, validator2, validator3, bridge, treasury] = await ethers.getSigners();

        // Deploy mock bridge and treasury contracts (using admin address for now)
        const mockBridge = bridge.address;
        const mockTreasury = treasury.address;
        const minimumValidators = 2;

        // Deploy OmniCoinCore
        const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
        const omniCoinCore = await OmniCoinCore.deploy(
            admin.address,
            mockBridge,
            mockTreasury,
            minimumValidators
        );

        // Mint initial supply after deployment
        // This is critical for both testnet and mainnet deployments
        await omniCoinCore.connect(admin).mintInitialSupply();

        return {
            omniCoinCore,
            admin,
            user1,
            user2,
            validator1,
            validator2,
            validator3,
            bridge,
            treasury,
            mockBridge,
            mockTreasury,
            minimumValidators
        };
    }

    describe("Deployment", function () {
        it("Should set the correct name and symbol", async function () {
            const { omniCoinCore } = await loadFixture(deployOmniCoinCoreFixture);

            expect(await omniCoinCore.name()).to.equal("OmniCoin");
            expect(await omniCoinCore.symbol()).to.equal("OMNI");
        });

        it("Should set the correct decimals", async function () {
            const { omniCoinCore } = await loadFixture(deployOmniCoinCoreFixture);

            expect(await omniCoinCore.decimals()).to.equal(6);
        });

        it("Should grant correct roles to admin", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            const DEFAULT_ADMIN_ROLE = await omniCoinCore.DEFAULT_ADMIN_ROLE();
            
            expect(await omniCoinCore.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await omniCoinCore.hasRole(MINTER_ROLE, admin.address)).to.be.true;
            expect(await omniCoinCore.hasRole(BURNER_ROLE, admin.address)).to.be.true;
            expect(await omniCoinCore.hasRole(PAUSER_ROLE, admin.address)).to.be.true;
        });

        it("Should set correct bridge and treasury contracts", async function () {
            const { omniCoinCore, mockBridge, mockTreasury } = await loadFixture(deployOmniCoinCoreFixture);

            expect(await omniCoinCore.bridgeContract()).to.equal(mockBridge);
            expect(await omniCoinCore.treasuryContract()).to.equal(mockTreasury);
        });

        it("Should set correct minimum validators", async function () {
            const { omniCoinCore, minimumValidators } = await loadFixture(deployOmniCoinCoreFixture);

            expect(await omniCoinCore.minimumValidators()).to.equal(minimumValidators);
        });

        it("Should revert with zero admin address", async function () {
            const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
            
            await expect(
                OmniCoinCore.deploy(
                    ethers.ZeroAddress,
                    ethers.ZeroAddress,
                    ethers.ZeroAddress,
                    1
                )
            ).to.be.revertedWith("OmniCoinCore: Admin cannot be zero address");
        });

        it("Should revert with zero minimum validators", async function () {
            const [admin] = await ethers.getSigners();
            const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
            
            await expect(
                OmniCoinCore.deploy(
                    admin.address,
                    ethers.ZeroAddress,
                    ethers.ZeroAddress,
                    0
                )
            ).to.be.revertedWith("OmniCoinCore: Minimum validators must be > 0");
        });
    });

    describe("Validator Management", function () {
        it("Should add validator successfully", async function () {
            const { omniCoinCore, admin, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(admin).addValidator(validator1.address))
                .to.emit(omniCoinCore, "ValidatorAdded")
                .withArgs(validator1.address);

            expect(await omniCoinCore.isValidator(validator1.address)).to.be.true;
            expect(await omniCoinCore.validatorCount()).to.equal(1);
            expect(await omniCoinCore.hasRole(VALIDATOR_ROLE, validator1.address)).to.be.true;
        });

        it("Should remove validator successfully", async function () {
            const { omniCoinCore, admin, validator1, validator2, validator3 } = await loadFixture(deployOmniCoinCoreFixture);

            // Add three validators first
            await omniCoinCore.connect(admin).addValidator(validator1.address);
            await omniCoinCore.connect(admin).addValidator(validator2.address);
            await omniCoinCore.connect(admin).addValidator(validator3.address);

            await expect(omniCoinCore.connect(admin).removeValidator(validator1.address))
                .to.emit(omniCoinCore, "ValidatorRemoved")
                .withArgs(validator1.address);

            expect(await omniCoinCore.isValidator(validator1.address)).to.be.false;
            expect(await omniCoinCore.validatorCount()).to.equal(2);
            expect(await omniCoinCore.hasRole(VALIDATOR_ROLE, validator1.address)).to.be.false;
        });

        it("Should revert when adding zero address as validator", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(admin).addValidator(ethers.ZeroAddress))
                .to.be.revertedWith("OmniCoinCore: Validator cannot be zero address");
        });

        it("Should revert when adding duplicate validator", async function () {
            const { omniCoinCore, admin, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            await omniCoinCore.connect(admin).addValidator(validator1.address);

            await expect(omniCoinCore.connect(admin).addValidator(validator1.address))
                .to.be.revertedWith("OmniCoinCore: Validator already exists");
        });

        it("Should revert when removing non-existent validator", async function () {
            const { omniCoinCore, admin, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(admin).removeValidator(validator1.address))
                .to.be.revertedWith("OmniCoinCore: Validator does not exist");
        });

        it("Should revert when removing validator would go below minimum", async function () {
            const { omniCoinCore, admin, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            // Add minimum number of validators (2)
            await omniCoinCore.connect(admin).addValidator(validator1.address);

            await expect(omniCoinCore.connect(admin).removeValidator(validator1.address))
                .to.be.revertedWith("OmniCoinCore: Cannot go below minimum validators");
        });

        it("Should only allow admin to add/remove validators", async function () {
            const { omniCoinCore, user1, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(user1).addValidator(validator1.address))
                .to.be.reverted;

            await expect(omniCoinCore.connect(user1).removeValidator(validator1.address))
                .to.be.reverted;
        });
    });

    describe("Privacy Functions", function () {
        it("Should set privacy preference successfully", async function () {
            const { omniCoinCore, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(user1).setPrivacyPreference(true))
                .to.emit(omniCoinCore, "PrivacyPreferenceChanged")
                .withArgs(user1.address, true);

            expect(await omniCoinCore.getPrivacyPreference(user1.address)).to.be.true;
        });

        it("Should return false for default privacy preference", async function () {
            const { omniCoinCore, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            expect(await omniCoinCore.getPrivacyPreference(user1.address)).to.be.false;
        });
    });

    describe("Validator Operations", function () {
        it("Should submit validator operation successfully", async function () {
            const { omniCoinCore, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            const operationData = ethers.toUtf8Bytes("test operation");
            const operationType = 1;

            const tx = await omniCoinCore.connect(user1).submitToValidators(operationData, operationType);
            const receipt = await tx.wait();

            // Find the ValidatorOperationSubmitted event
            const event = receipt.logs.find(log => {
                try {
                    const parsedLog = omniCoinCore.interface.parseLog(log);
                    return parsedLog.name === "ValidatorOperationSubmitted";
                } catch {
                    return false;
                }
            });

            expect(event).to.not.be.undefined;
            
            const parsedEvent = omniCoinCore.interface.parseLog(event);
            const operationHash = parsedEvent.args.operationHash;

            const operation = await omniCoinCore.getValidatorOperation(operationHash);
            expect(operation[0]).to.equal(operationHash); // operationHash
            expect(operation[1]).to.deep.equal([]); // validators array (empty initially)
            expect(operation[2]).to.equal(0); // confirmations
            expect(operation[3]).to.be.false; // executed
            expect(operation[4]).to.be.gt(0); // timestamp
        });

        it("Should confirm validator operation successfully", async function () {
            const { omniCoinCore, admin, user1, validator1, validator2 } = await loadFixture(deployOmniCoinCoreFixture);

            // Add validators
            await omniCoinCore.connect(admin).addValidator(validator1.address);
            await omniCoinCore.connect(admin).addValidator(validator2.address);

            // Submit operation
            const operationData = ethers.toUtf8Bytes("test operation");
            const operationType = 1;

            const tx = await omniCoinCore.connect(user1).submitToValidators(operationData, operationType);
            const receipt = await tx.wait();

            const event = receipt.logs.find(log => {
                try {
                    const parsedLog = omniCoinCore.interface.parseLog(log);
                    return parsedLog.name === "ValidatorOperationSubmitted";
                } catch {
                    return false;
                }
            });

            const parsedEvent = omniCoinCore.interface.parseLog(event);
            const operationHash = parsedEvent.args.operationHash;

            // Confirm with first validator
            await omniCoinCore.connect(validator1).confirmValidatorOperation(operationHash);

            let operation = await omniCoinCore.getValidatorOperation(operationHash);
            expect(operation[2]).to.equal(1); // confirmations
            expect(operation[3]).to.be.false; // not executed yet

            // Confirm with second validator (should execute)
            await expect(omniCoinCore.connect(validator2).confirmValidatorOperation(operationHash))
                .to.emit(omniCoinCore, "ValidatorOperationExecuted")
                .withArgs(operationHash, 2);

            operation = await omniCoinCore.getValidatorOperation(operationHash);
            expect(operation[2]).to.equal(2); // confirmations
            expect(operation[3]).to.be.true; // executed
        });

        it("Should revert when non-validator tries to confirm", async function () {
            const { omniCoinCore, user1, user2 } = await loadFixture(deployOmniCoinCoreFixture);

            // Submit operation
            const operationData = ethers.toUtf8Bytes("test operation");
            const operationType = 1;

            const tx = await omniCoinCore.connect(user1).submitToValidators(operationData, operationType);
            const receipt = await tx.wait();

            const event = receipt.logs.find(log => {
                try {
                    const parsedLog = omniCoinCore.interface.parseLog(log);
                    return parsedLog.name === "ValidatorOperationSubmitted";
                } catch {
                    return false;
                }
            });

            const parsedEvent = omniCoinCore.interface.parseLog(event);
            const operationHash = parsedEvent.args.operationHash;

            await expect(omniCoinCore.connect(user2).confirmValidatorOperation(operationHash))
                .to.be.revertedWith("OmniCoinCore: Not a registered validator");
        });

        it("Should revert when validator tries to confirm twice", async function () {
            const { omniCoinCore, admin, user1, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            // Add validator
            await omniCoinCore.connect(admin).addValidator(validator1.address);

            // Submit operation
            const operationData = ethers.toUtf8Bytes("test operation");
            const operationType = 1;

            const tx = await omniCoinCore.connect(user1).submitToValidators(operationData, operationType);
            const receipt = await tx.wait();

            const event = receipt.logs.find(log => {
                try {
                    const parsedLog = omniCoinCore.interface.parseLog(log);
                    return parsedLog.name === "ValidatorOperationSubmitted";
                } catch {
                    return false;
                }
            });

            const parsedEvent = omniCoinCore.interface.parseLog(event);
            const operationHash = parsedEvent.args.operationHash;

            // First confirmation
            await omniCoinCore.connect(validator1).confirmValidatorOperation(operationHash);

            // Second confirmation should fail
            await expect(omniCoinCore.connect(validator1).confirmValidatorOperation(operationHash))
                .to.be.revertedWith("OmniCoinCore: Already confirmed");
        });
    });

    describe("Admin Functions", function () {
        it("Should update bridge contract successfully", async function () {
            const { omniCoinCore, admin, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            const newBridge = user1.address;

            await expect(omniCoinCore.connect(admin).setBridgeContract(newBridge))
                .to.emit(omniCoinCore, "BridgeContractUpdated");

            expect(await omniCoinCore.bridgeContract()).to.equal(newBridge);
            expect(await omniCoinCore.hasRole(BRIDGE_ROLE, newBridge)).to.be.true;
        });

        it("Should update treasury contract successfully", async function () {
            const { omniCoinCore, admin, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            const newTreasury = user1.address;

            await expect(omniCoinCore.connect(admin).setTreasuryContract(newTreasury))
                .to.emit(omniCoinCore, "TreasuryContractUpdated");

            expect(await omniCoinCore.treasuryContract()).to.equal(newTreasury);
        });

        it("Should update minimum validators successfully", async function () {
            const { omniCoinCore, admin, validator1, validator2 } = await loadFixture(deployOmniCoinCoreFixture);

            // Add validators first
            await omniCoinCore.connect(admin).addValidator(validator1.address);
            await omniCoinCore.connect(admin).addValidator(validator2.address);

            await omniCoinCore.connect(admin).setMinimumValidators(1);

            expect(await omniCoinCore.minimumValidators()).to.equal(1);
        });

        it("Should revert when setting bridge to zero address", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(admin).setBridgeContract(ethers.ZeroAddress))
                .to.be.revertedWith("OmniCoinCore: Bridge cannot be zero address");
        });

        it("Should revert when setting treasury to zero address", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(admin).setTreasuryContract(ethers.ZeroAddress))
                .to.be.revertedWith("OmniCoinCore: Treasury cannot be zero address");
        });

        it("Should revert when setting minimum validators to zero", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(admin).setMinimumValidators(0))
                .to.be.revertedWith("OmniCoinCore: Minimum must be > 0");
        });

        it("Should revert when setting minimum validators above current count", async function () {
            const { omniCoinCore, admin, validator1 } = await loadFixture(deployOmniCoinCoreFixture);

            // Add only one validator
            await omniCoinCore.connect(admin).addValidator(validator1.address);

            await expect(omniCoinCore.connect(admin).setMinimumValidators(5))
                .to.be.revertedWith("OmniCoinCore: Minimum cannot exceed current count");
        });

        it("Should only allow admin to call admin functions", async function () {
            const { omniCoinCore, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(user1).setBridgeContract(user1.address))
                .to.be.reverted;

            await expect(omniCoinCore.connect(user1).setTreasuryContract(user1.address))
                .to.be.reverted;

            await expect(omniCoinCore.connect(user1).setMinimumValidators(1))
                .to.be.reverted;
        });
    });

    describe("Pausable Functions", function () {
        it("Should pause and unpause successfully", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            await omniCoinCore.connect(admin).pause();
            expect(await omniCoinCore.paused()).to.be.true;

            await omniCoinCore.connect(admin).unpause();
            expect(await omniCoinCore.paused()).to.be.false;
        });

        it("Should only allow pauser role to pause/unpause", async function () {
            const { omniCoinCore, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(user1).pause())
                .to.be.reverted;

            await expect(omniCoinCore.connect(user1).unpause())
                .to.be.reverted;
        });
    });

    describe("Emergency Functions", function () {
        it("Should emergency stop validator operations", async function () {
            const { omniCoinCore, admin } = await loadFixture(deployOmniCoinCoreFixture);

            await omniCoinCore.connect(admin).emergencyStopValidatorOperations();
            expect(await omniCoinCore.paused()).to.be.true;
        });

        it("Should emergency execute operation after 24 hours", async function () {
            const { omniCoinCore, admin, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            // Submit operation
            const operationData = ethers.toUtf8Bytes("test operation");
            const operationType = 1;

            const tx = await omniCoinCore.connect(user1).submitToValidators(operationData, operationType);
            const receipt = await tx.wait();

            const event = receipt.logs.find(log => {
                try {
                    const parsedLog = omniCoinCore.interface.parseLog(log);
                    return parsedLog.name === "ValidatorOperationSubmitted";
                } catch {
                    return false;
                }
            });

            const parsedEvent = omniCoinCore.interface.parseLog(event);
            const operationHash = parsedEvent.args.operationHash;

            // Should revert before 24 hours
            await expect(omniCoinCore.connect(admin).emergencyExecuteOperation(operationHash))
                .to.be.revertedWith("OmniCoinCore: Must wait 24 hours before emergency execution");

            // Fast forward 24 hours + 1 minute
            await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 60]);
            await ethers.provider.send("evm_mine");

            // Should succeed after 24 hours
            await expect(omniCoinCore.connect(admin).emergencyExecuteOperation(operationHash))
                .to.emit(omniCoinCore, "ValidatorOperationExecuted")
                .withArgs(operationHash, 0);

            const operation = await omniCoinCore.getValidatorOperation(operationHash);
            expect(operation[3]).to.be.true; // executed
        });

        it("Should only allow admin to call emergency functions", async function () {
            const { omniCoinCore, user1 } = await loadFixture(deployOmniCoinCoreFixture);

            await expect(omniCoinCore.connect(user1).emergencyStopValidatorOperations())
                .to.be.reverted;

            await expect(omniCoinCore.connect(user1).emergencyExecuteOperation(ethers.ZeroHash))
                .to.be.reverted;
        });
    });

    describe("Integration with COTI Privacy Features", function () {
        // Note: These tests would require the full COTI MPC environment
        // For now, we test the contract structure and basic functionality
        
        it("Should inherit from PrivateERC20", async function () {
            const { omniCoinCore } = await loadFixture(deployOmniCoinCoreFixture);

            // Check that privacy-related functions exist
            expect(typeof omniCoinCore.setAccountEncryptionAddress).to.equal("function");
            expect(typeof omniCoinCore.accountEncryptionAddress).to.equal("function");
        });

        it("Should have privacy preference functions", async function () {
            const { omniCoinCore } = await loadFixture(deployOmniCoinCoreFixture);

            expect(typeof omniCoinCore.setPrivacyPreference).to.equal("function");
            expect(typeof omniCoinCore.getPrivacyPreference).to.equal("function");
        });
    });
});