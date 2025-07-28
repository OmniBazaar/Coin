const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ValidatorRegistry", function () {
    let owner, validator1, validator2, validator3, manager, slasher, oracle, user, treasury;
    let registry, omniCoin, privateOmniCoin;
    let validatorRegistry;
    
    // Constants from contract
    const MIN_CPU_CORES = 4;
    const MIN_RAM_GB = 8;
    const MIN_STORAGE_GB = 100;
    const MIN_NETWORK_SPEED = 100;
    const MAX_PARTICIPATION_SCORE = 100;
    
    // Default staking config
    const DEFAULT_MIN_STAKE = ethers.parseUnits("1000", 6);
    const DEFAULT_MAX_STAKE = ethers.parseUnits("100000", 6);
    const DEFAULT_SLASHING_RATE = 1000; // 10%
    const DEFAULT_REWARD_RATE = 500; // 5% annual
    const DEFAULT_UNSTAKING_PERIOD = 7 * 24 * 60 * 60; // 7 days
    const DEFAULT_PARTICIPATION_THRESHOLD = 50;
    
    beforeEach(async function () {
        [owner, validator1, validator2, validator3, manager, slasher, oracle, user, treasury] = await ethers.getSigners();
        
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
        
        // Deploy ValidatorRegistry
        const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
        validatorRegistry = await ValidatorRegistry.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await validatorRegistry.waitForDeployment();
        
        // Setup roles
        await validatorRegistry.connect(owner).grantRole(
            await validatorRegistry.VALIDATOR_MANAGER_ROLE(),
            await manager.getAddress()
        );
        await validatorRegistry.connect(owner).grantRole(
            await validatorRegistry.SLASHER_ROLE(),
            await slasher.getAddress()
        );
        await validatorRegistry.connect(owner).grantRole(
            await validatorRegistry.ORACLE_ROLE(),
            await oracle.getAddress()
        );
        
        // Fund validators
        const fundAmount = ethers.parseUnits("50000", 6);
        await omniCoin.mint(await validator1.getAddress(), fundAmount);
        await omniCoin.mint(await validator2.getAddress(), fundAmount);
        await omniCoin.mint(await validator3.getAddress(), fundAmount);
        
        // Approve registry
        await omniCoin.connect(validator1).approve(await validatorRegistry.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(validator2).approve(await validatorRegistry.getAddress(), ethers.MaxUint256);
        await omniCoin.connect(validator3).approve(await validatorRegistry.getAddress(), ethers.MaxUint256);
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            const config = await validatorRegistry.stakingConfig();
            expect(config.minimumStake).to.equal(DEFAULT_MIN_STAKE);
            expect(config.maximumStake).to.equal(DEFAULT_MAX_STAKE);
            expect(config.slashingRate).to.equal(DEFAULT_SLASHING_RATE);
            expect(config.rewardRate).to.equal(DEFAULT_REWARD_RATE);
            expect(config.unstakingPeriod).to.equal(DEFAULT_UNSTAKING_PERIOD);
            expect(config.participationThreshold).to.equal(DEFAULT_PARTICIPATION_THRESHOLD);
            
            expect(await validatorRegistry.epochDuration()).to.equal(3600); // 1 hour
            expect(await validatorRegistry.totalValidators()).to.equal(0);
            expect(await validatorRegistry.activeValidators()).to.equal(0);
        });
        
        it("Should update staking config", async function () {
            const newConfig = {
                minimumStake: ethers.parseUnits("2000", 6),
                maximumStake: ethers.parseUnits("200000", 6),
                slashingRate: 2000, // 20%
                rewardRate: 1000, // 10%
                unstakingPeriod: 14 * 24 * 60 * 60, // 14 days
                participationThreshold: 60
            };
            
            await expect(
                validatorRegistry.connect(manager).updateStakingConfig(
                    newConfig.minimumStake,
                    newConfig.maximumStake,
                    newConfig.slashingRate,
                    newConfig.rewardRate,
                    newConfig.unstakingPeriod,
                    newConfig.participationThreshold
                )
            ).to.emit(validatorRegistry, "StakingConfigUpdated");
            
            const config = await validatorRegistry.stakingConfig();
            expect(config.minimumStake).to.equal(newConfig.minimumStake);
            expect(config.maximumStake).to.equal(newConfig.maximumStake);
            expect(config.slashingRate).to.equal(newConfig.slashingRate);
            expect(config.rewardRate).to.equal(newConfig.rewardRate);
            expect(config.unstakingPeriod).to.equal(newConfig.unstakingPeriod);
            expect(config.participationThreshold).to.equal(newConfig.participationThreshold);
        });
        
        it("Should update epoch duration", async function () {
            const newDuration = 2 * 60 * 60; // 2 hours
            
            await expect(validatorRegistry.connect(manager).updateEpochDuration(newDuration))
                .to.emit(validatorRegistry, "EpochDurationUpdated")
                .withArgs(3600, newDuration);
            
            expect(await validatorRegistry.epochDuration()).to.equal(newDuration);
        });
    });
    
    describe("Validator Registration", function () {
        const hardwareSpecs = {
            cpuCores: 8,
            ramGB: 16,
            storageGB: 500,
            networkSpeed: 1000,
            verified: true,
            verificationTime: 0 // Will be set by contract
        };
        
        it("Should register validator with valid specs", async function () {
            const stakeAmount = ethers.parseUnits("5000", 6);
            const nodeId = "validator1-node-123";
            
            await expect(
                validatorRegistry.connect(validator1).registerValidator(
                    stakeAmount,
                    nodeId,
                    hardwareSpecs
                )
            ).to.emit(validatorRegistry, "ValidatorRegistered")
                .withArgs(await validator1.getAddress(), stakeAmount, nodeId, await ethers.provider.getBlock().then(b => b.timestamp + 1));
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            expect(validatorInfo.validatorAddress).to.equal(await validator1.getAddress());
            expect(validatorInfo.stakedAmount).to.equal(stakeAmount);
            expect(validatorInfo.participationScore).to.equal(MAX_PARTICIPATION_SCORE);
            expect(validatorInfo.status).to.equal(1); // ValidatorStatus.ACTIVE
            expect(validatorInfo.nodeId).to.equal(nodeId);
            
            expect(await validatorRegistry.totalValidators()).to.equal(1);
            expect(await validatorRegistry.activeValidators()).to.equal(1);
            expect(await validatorRegistry.totalStaked()).to.equal(stakeAmount);
        });
        
        it("Should reject registration with insufficient hardware", async function () {
            const insufficientSpecs = {
                cpuCores: 2, // Below minimum
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await expect(
                validatorRegistry.connect(validator1).registerValidator(
                    DEFAULT_MIN_STAKE,
                    "node-123",
                    insufficientSpecs
                )
            ).to.be.revertedWithCustomError(validatorRegistry, "InsufficientHardware");
        });
        
        it("Should reject registration with insufficient stake", async function () {
            await expect(
                validatorRegistry.connect(validator1).registerValidator(
                    ethers.parseUnits("500", 6), // Below minimum
                    "node-123",
                    hardwareSpecs
                )
            ).to.be.revertedWithCustomError(validatorRegistry, "InsufficientStake");
        });
        
        it("Should reject duplicate node ID", async function () {
            const nodeId = "duplicate-node";
            await validatorRegistry.connect(validator1).registerValidator(
                DEFAULT_MIN_STAKE,
                nodeId,
                hardwareSpecs
            );
            
            await expect(
                validatorRegistry.connect(validator2).registerValidator(
                    DEFAULT_MIN_STAKE,
                    nodeId,
                    hardwareSpecs
                )
            ).to.be.revertedWithCustomError(validatorRegistry, "NodeIdAlreadyExists");
        });
        
        it("Should reject already registered validator", async function () {
            await validatorRegistry.connect(validator1).registerValidator(
                DEFAULT_MIN_STAKE,
                "node-123",
                hardwareSpecs
            );
            
            await expect(
                validatorRegistry.connect(validator1).registerValidator(
                    DEFAULT_MIN_STAKE,
                    "node-456",
                    hardwareSpecs
                )
            ).to.be.revertedWithCustomError(validatorRegistry, "AlreadyRegistered");
        });
    });
    
    describe("Stake Management", function () {
        beforeEach(async function () {
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await validatorRegistry.connect(validator1).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator1-node",
                hardwareSpecs
            );
        });
        
        it("Should increase validator stake", async function () {
            const additionalStake = ethers.parseUnits("2000", 6);
            const initialStake = (await validatorRegistry.validators(await validator1.getAddress())).stakedAmount;
            
            await expect(
                validatorRegistry.connect(validator1).increaseStake(additionalStake)
            ).to.emit(validatorRegistry, "ValidatorStakeIncreased")
                .withArgs(await validator1.getAddress(), additionalStake, initialStake + additionalStake);
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            expect(validatorInfo.stakedAmount).to.equal(initialStake + additionalStake);
            expect(await validatorRegistry.totalStaked()).to.equal(initialStake + additionalStake);
        });
        
        it("Should reject stake increase exceeding maximum", async function () {
            const tooMuchStake = ethers.parseUnits("200000", 6);
            
            await expect(
                validatorRegistry.connect(validator1).increaseStake(tooMuchStake)
            ).to.be.revertedWithCustomError(validatorRegistry, "StakeExceedsMaximum");
        });
    });
    
    describe("Deregistration", function () {
        beforeEach(async function () {
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await validatorRegistry.connect(validator1).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator1-node",
                hardwareSpecs
            );
        });
        
        it("Should request deregistration", async function () {
            await expect(validatorRegistry.connect(validator1).requestDeregistration())
                .to.emit(validatorRegistry, "ValidatorStatusChanged")
                .withArgs(await validator1.getAddress(), 1, 4); // ACTIVE to EXITING
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            expect(validatorInfo.status).to.equal(4); // ValidatorStatus.EXITING
            expect(await validatorRegistry.activeValidators()).to.equal(0);
        });
        
        it("Should complete deregistration after unstaking period", async function () {
            await validatorRegistry.connect(validator1).requestDeregistration();
            
            // Fast forward past unstaking period
            await ethers.provider.send("evm_increaseTime", [DEFAULT_UNSTAKING_PERIOD]);
            await ethers.provider.send("evm_mine");
            
            const stakeAmount = (await validatorRegistry.validators(await validator1.getAddress())).stakedAmount;
            const balanceBefore = await omniCoin.balanceOf(await validator1.getAddress());
            
            await expect(validatorRegistry.connect(validator1).completeDeregistration())
                .to.emit(validatorRegistry, "ValidatorDeregistered");
            
            expect(await omniCoin.balanceOf(await validator1.getAddress()))
                .to.equal(balanceBefore + stakeAmount);
            expect(await validatorRegistry.totalValidators()).to.equal(0);
            expect(await validatorRegistry.totalStaked()).to.equal(0);
        });
        
        it("Should not complete deregistration before unstaking period", async function () {
            await validatorRegistry.connect(validator1).requestDeregistration();
            
            await expect(
                validatorRegistry.connect(validator1).completeDeregistration()
            ).to.be.revertedWithCustomError(validatorRegistry, "UnstakingPeriodNotCompleted");
        });
    });
    
    describe("Performance Updates", function () {
        beforeEach(async function () {
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await validatorRegistry.connect(validator1).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator1-node",
                hardwareSpecs
            );
            
            await validatorRegistry.connect(validator2).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator2-node",
                hardwareSpecs
            );
        });
        
        it("Should update validator performance metrics", async function () {
            const updates = [{
                validator: await validator1.getAddress(),
                blocksProduced: 100,
                uptime: 9900, // 99%
                tradingVolumeFacilitated: ethers.parseUnits("10000", 6),
                chatMessages: 50,
                ipfsDataStored: 1000000 // 1MB
            }];
            
            await expect(
                validatorRegistry.connect(oracle).updatePerformanceMetrics(updates)
            ).to.emit(validatorRegistry, "PerformanceUpdated")
                .withArgs(await validator1.getAddress());
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            expect(validatorInfo.performance.blocksProduced).to.equal(100);
            expect(validatorInfo.performance.uptime).to.equal(9900);
            expect(validatorInfo.performance.tradingVolumeFacilitated).to.equal(ethers.parseUnits("10000", 6));
            expect(validatorInfo.performance.chatMessages).to.equal(50);
            expect(validatorInfo.performance.ipfsDataStored).to.equal(1000000);
        });
        
        it("Should only allow oracle to update performance", async function () {
            const updates = [{
                validator: await validator1.getAddress(),
                blocksProduced: 100,
                uptime: 10000,
                tradingVolumeFacilitated: 0,
                chatMessages: 0,
                ipfsDataStored: 0
            }];
            
            await expect(
                validatorRegistry.connect(user).updatePerformanceMetrics(updates)
            ).to.be.revertedWithCustomError(validatorRegistry, "AccessControlUnauthorizedAccount");
        });
    });
    
    describe("Slashing", function () {
        beforeEach(async function () {
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await validatorRegistry.connect(validator1).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator1-node",
                hardwareSpecs
            );
        });
        
        it("Should slash validator for offense", async function () {
            const slashingOffense = 1; // DOUBLE_SIGNING
            const initialStake = (await validatorRegistry.validators(await validator1.getAddress())).stakedAmount;
            const expectedSlash = (initialStake * BigInt(DEFAULT_SLASHING_RATE)) / 10000n;
            
            await expect(
                validatorRegistry.connect(slasher).slashValidator(
                    await validator1.getAddress(),
                    slashingOffense
                )
            ).to.emit(validatorRegistry, "ValidatorSlashed")
                .withArgs(await validator1.getAddress(), expectedSlash, slashingOffense);
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            expect(validatorInfo.stakedAmount).to.equal(initialStake - expectedSlash);
            expect(validatorInfo.slashingHistory).to.be.gt(0);
        });
        
        it("Should jail validator for repeated offenses", async function () {
            // Slash multiple times
            for (let i = 0; i < 3; i++) {
                await validatorRegistry.connect(slasher).slashValidator(
                    await validator1.getAddress(),
                    1 // DOUBLE_SIGNING
                );
            }
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            expect(validatorInfo.status).to.equal(3); // ValidatorStatus.JAILED
        });
        
        it("Should only allow slasher role to slash", async function () {
            await expect(
                validatorRegistry.connect(user).slashValidator(
                    await validator1.getAddress(),
                    1
                )
            ).to.be.revertedWithCustomError(validatorRegistry, "AccessControlUnauthorizedAccount");
        });
    });
    
    describe("Participation Score", function () {
        beforeEach(async function () {
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await validatorRegistry.connect(validator1).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator1-node",
                hardwareSpecs
            );
            
            // Update performance metrics
            const updates = [{
                validator: await validator1.getAddress(),
                blocksProduced: 1000,
                uptime: 9500, // 95%
                tradingVolumeFacilitated: ethers.parseUnits("50000", 6),
                chatMessages: 200,
                ipfsDataStored: 10000000 // 10MB
            }];
            
            await validatorRegistry.connect(oracle).updatePerformanceMetrics(updates);
        });
        
        it("Should calculate participation score correctly", async function () {
            await validatorRegistry.connect(manager).recalculateParticipationScores();
            
            const validatorInfo = await validatorRegistry.validators(await validator1.getAddress());
            // Score should be calculated based on weights
            expect(validatorInfo.participationScore).to.be.gt(0);
            expect(validatorInfo.participationScore).to.be.lte(MAX_PARTICIPATION_SCORE);
        });
        
        it("Should trigger new epoch and update scores", async function () {
            // Fast forward past epoch duration
            await ethers.provider.send("evm_increaseTime", [3601]); // 1 hour + 1 second
            await ethers.provider.send("evm_mine");
            
            const epochBefore = await validatorRegistry.currentEpoch();
            
            await expect(validatorRegistry.connect(manager).triggerNewEpoch())
                .to.emit(validatorRegistry, "NewEpoch")
                .withArgs(epochBefore + 1n);
            
            expect(await validatorRegistry.currentEpoch()).to.equal(epochBefore + 1n);
        });
    });
    
    describe("Validator Selection", function () {
        beforeEach(async function () {
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            // Register multiple validators with different stakes
            await validatorRegistry.connect(validator1).registerValidator(
                ethers.parseUnits("10000", 6),
                "validator1-node",
                hardwareSpecs
            );
            
            await validatorRegistry.connect(validator2).registerValidator(
                ethers.parseUnits("5000", 6),
                "validator2-node",
                hardwareSpecs
            );
            
            await validatorRegistry.connect(validator3).registerValidator(
                ethers.parseUnits("15000", 6),
                "validator3-node",
                hardwareSpecs
            );
        });
        
        it("Should get top validators by stake", async function () {
            const topValidators = await validatorRegistry.getTopValidatorsByStake(2);
            
            expect(topValidators.length).to.equal(2);
            expect(topValidators[0]).to.equal(await validator3.getAddress()); // Highest stake
            expect(topValidators[1]).to.equal(await validator1.getAddress()); // Second highest
        });
        
        it("Should get validators for consensus", async function () {
            const consensusValidators = await validatorRegistry.getValidatorsForConsensus(3);
            
            expect(consensusValidators.length).to.equal(3);
            expect(consensusValidators).to.include(await validator1.getAddress());
            expect(consensusValidators).to.include(await validator2.getAddress());
            expect(consensusValidators).to.include(await validator3.getAddress());
        });
    });
    
    describe("Emergency Functions", function () {
        it("Should pause and unpause", async function () {
            await validatorRegistry.connect(owner).pause();
            expect(await validatorRegistry.paused()).to.be.true;
            
            const hardwareSpecs = {
                cpuCores: 8,
                ramGB: 16,
                storageGB: 500,
                networkSpeed: 1000,
                verified: true,
                verificationTime: 0
            };
            
            await expect(
                validatorRegistry.connect(validator1).registerValidator(
                    ethers.parseUnits("5000", 6),
                    "validator1-node",
                    hardwareSpecs
                )
            ).to.be.revertedWithCustomError(validatorRegistry, "EnforcedPause");
            
            await validatorRegistry.connect(owner).unpause();
            expect(await validatorRegistry.paused()).to.be.false;
        });
    });
});