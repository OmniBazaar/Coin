const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("ValidatorSync", function () {
  async function deployValidatorSyncFixture() {
    const [owner, validator1, validator2, validator3, unauthorized] = await ethers.getSigners();

    // Deploy actual OmniCoinRegistry
    const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await OmniCoinRegistry.deploy(await owner.getAddress());
    await registry.waitForDeployment();

    // Deploy actual OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy(await registry.getAddress());
    await omniCoin.waitForDeployment();

    // Deploy actual ValidatorRegistry
    const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
    const validatorRegistry = await ValidatorRegistry.deploy(
      await registry.getAddress(),
      await owner.getAddress()
    );
    await validatorRegistry.waitForDeployment();

    // Deploy ValidatorSync
    const ValidatorSync = await ethers.getContractFactory("ValidatorSync");
    const validatorSync = await ValidatorSync.deploy(
      await validatorRegistry.getAddress(),
      await owner.getAddress()
    );
    await validatorSync.waitForDeployment();

    // Set up registry
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
      await omniCoin.getAddress()
    );
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("VALIDATOR_REGISTRY")),
      await validatorRegistry.getAddress()
    );
    await registry.setContract(
      ethers.keccak256(ethers.toUtf8Bytes("VALIDATOR_SYNC")),
      await validatorSync.getAddress()
    );

    // Grant necessary roles
    const VALIDATOR_ROLE = await validatorSync.VALIDATOR_ROLE();
    await validatorSync.grantRole(VALIDATOR_ROLE, await validator1.getAddress());
    await validatorSync.grantRole(VALIDATOR_ROLE, await validator2.getAddress());
    await validatorSync.grantRole(VALIDATOR_ROLE, await validator3.getAddress());

    // Register validators in the registry
    const REGISTRAR_ROLE = await validatorRegistry.REGISTRAR_ROLE();
    await validatorRegistry.grantRole(REGISTRAR_ROLE, await owner.getAddress());
    
    await validatorRegistry.registerValidator(await validator1.getAddress());
    await validatorRegistry.registerValidator(await validator2.getAddress());
    await validatorRegistry.registerValidator(await validator3.getAddress());

    return {
      validatorSync,
      validatorRegistry,
      omniCoin,
      registry,
      owner,
      validator1,
      validator2,
      validator3,
      unauthorized
    };
  }

  describe("Deployment", function () {
    it("Should set correct initial values", async function () {
      const { validatorSync, validatorRegistry, owner } = await loadFixture(deployValidatorSyncFixture);

      expect(await validatorSync.validatorRegistry()).to.equal(await validatorRegistry.getAddress());
      expect(await validatorSync.consensusThreshold()).to.equal(67); // 67%
      expect(await validatorSync.syncTimeWindow()).to.equal(300); // 5 minutes
      
      const DEFAULT_ADMIN_ROLE = await validatorSync.DEFAULT_ADMIN_ROLE();
      expect(await validatorSync.hasRole(DEFAULT_ADMIN_ROLE, await owner.getAddress())).to.be.true;
    });
  });

  describe("State Synchronization", function () {
    it("Should submit and process state updates", async function () {
      const { validatorSync, validator1, validator2, validator3 } = await loadFixture(deployValidatorSyncFixture);

      const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      const blockNumber = 1000;
      const timestamp = Math.floor(Date.now() / 1000);

      // Submit state from validator1
      await expect(
        validatorSync.connect(validator1).submitStateUpdate(stateRoot, blockNumber, timestamp)
      ).to.emit(validatorSync, "StateUpdateSubmitted")
        .withArgs(await validator1.getAddress(), stateRoot, blockNumber, timestamp);

      // Submit state from validator2
      await expect(
        validatorSync.connect(validator2).submitStateUpdate(stateRoot, blockNumber, timestamp)
      ).to.emit(validatorSync, "StateUpdateSubmitted");

      // Submit state from validator3 - should reach consensus
      await expect(
        validatorSync.connect(validator3).submitStateUpdate(stateRoot, blockNumber, timestamp)
      ).to.emit(validatorSync, "ConsensusReached")
        .withArgs(stateRoot, blockNumber, 3);

      // Check the latest confirmed state
      const latestState = await validatorSync.getLatestConfirmedState();
      expect(latestState.stateRoot).to.equal(stateRoot);
      expect(latestState.blockNumber).to.equal(blockNumber);
      expect(latestState.timestamp).to.equal(timestamp);
      expect(latestState.validatorCount).to.equal(3);
    });

    it("Should reject unauthorized state submissions", async function () {
      const { validatorSync, unauthorized } = await loadFixture(deployValidatorSyncFixture);

      const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      const blockNumber = 1000;
      const timestamp = Math.floor(Date.now() / 1000);

      await expect(
        validatorSync.connect(unauthorized).submitStateUpdate(stateRoot, blockNumber, timestamp)
      ).to.be.revertedWithCustomError(validatorSync, "AccessControlUnauthorizedAccount");
    });

    it("Should handle conflicting state updates", async function () {
      const { validatorSync, validator1, validator2, validator3 } = await loadFixture(deployValidatorSyncFixture);

      const stateRoot1 = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      const stateRoot2 = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_2"));
      const blockNumber = 1000;
      const timestamp = Math.floor(Date.now() / 1000);

      // Validator1 submits stateRoot1
      await validatorSync.connect(validator1).submitStateUpdate(stateRoot1, blockNumber, timestamp);

      // Validator2 submits different stateRoot2
      await validatorSync.connect(validator2).submitStateUpdate(stateRoot2, blockNumber, timestamp);

      // Validator3 agrees with validator1 - should reach consensus on stateRoot1
      await expect(
        validatorSync.connect(validator3).submitStateUpdate(stateRoot1, blockNumber, timestamp)
      ).to.emit(validatorSync, "ConsensusReached")
        .withArgs(stateRoot1, blockNumber, 2);

      const latestState = await validatorSync.getLatestConfirmedState();
      expect(latestState.stateRoot).to.equal(stateRoot1);
    });
  });

  describe("Configuration Management", function () {
    it("Should update consensus threshold", async function () {
      const { validatorSync, owner } = await loadFixture(deployValidatorSyncFixture);

      const newThreshold = 75;
      await expect(
        validatorSync.connect(owner).setConsensusThreshold(newThreshold)
      ).to.emit(validatorSync, "ConsensusThresholdUpdated")
        .withArgs(67, newThreshold);

      expect(await validatorSync.consensusThreshold()).to.equal(newThreshold);
    });

    it("Should reject invalid consensus threshold", async function () {
      const { validatorSync, owner } = await loadFixture(deployValidatorSyncFixture);

      // Too low
      await expect(
        validatorSync.connect(owner).setConsensusThreshold(49)
      ).to.be.revertedWithCustomError(validatorSync, "InvalidThreshold");

      // Too high
      await expect(
        validatorSync.connect(owner).setConsensusThreshold(101)
      ).to.be.revertedWithCustomError(validatorSync, "InvalidThreshold");
    });

    it("Should update sync time window", async function () {
      const { validatorSync, owner } = await loadFixture(deployValidatorSyncFixture);

      const newWindow = 600; // 10 minutes
      await expect(
        validatorSync.connect(owner).setSyncTimeWindow(newWindow)
      ).to.emit(validatorSync, "SyncTimeWindowUpdated")
        .withArgs(300, newWindow);

      expect(await validatorSync.syncTimeWindow()).to.equal(newWindow);
    });
  });

  describe("Emergency Functions", function () {
    it("Should pause and unpause synchronization", async function () {
      const { validatorSync, owner, validator1 } = await loadFixture(deployValidatorSyncFixture);

      // Pause
      await expect(validatorSync.connect(owner).pause())
        .to.emit(validatorSync, "Paused");

      // Cannot submit when paused
      const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      await expect(
        validatorSync.connect(validator1).submitStateUpdate(stateRoot, 1000, Math.floor(Date.now() / 1000))
      ).to.be.revertedWithCustomError(validatorSync, "EnforcedPause");

      // Unpause
      await expect(validatorSync.connect(owner).unpause())
        .to.emit(validatorSync, "Unpaused");

      // Can submit again
      await expect(
        validatorSync.connect(validator1).submitStateUpdate(stateRoot, 1000, Math.floor(Date.now() / 1000))
      ).to.not.be.reverted;
    });

    it("Should force state update in emergency", async function () {
      const { validatorSync, owner } = await loadFixture(deployValidatorSyncFixture);

      const emergencyStateRoot = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_STATE"));
      const blockNumber = 2000;
      const timestamp = Math.floor(Date.now() / 1000);

      await expect(
        validatorSync.connect(owner).forceStateUpdate(emergencyStateRoot, blockNumber, timestamp)
      ).to.emit(validatorSync, "EmergencyStateUpdate")
        .withArgs(emergencyStateRoot, blockNumber, timestamp);

      const latestState = await validatorSync.getLatestConfirmedState();
      expect(latestState.stateRoot).to.equal(emergencyStateRoot);
      expect(latestState.blockNumber).to.equal(blockNumber);
    });
  });

  describe("Query Functions", function () {
    it("Should track validator participation", async function () {
      const { validatorSync, validator1, validator2 } = await loadFixture(deployValidatorSyncFixture);

      const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      const blockNumber = 1000;
      const timestamp = Math.floor(Date.now() / 1000);

      // Submit from two validators
      await validatorSync.connect(validator1).submitStateUpdate(stateRoot, blockNumber, timestamp);
      await validatorSync.connect(validator2).submitStateUpdate(stateRoot, blockNumber, timestamp);

      // Check participation
      expect(await validatorSync.getValidatorParticipation(await validator1.getAddress())).to.equal(1);
      expect(await validatorSync.getValidatorParticipation(await validator2.getAddress())).to.equal(1);
    });

    it("Should check if state is confirmed", async function () {
      const { validatorSync, validator1, validator2, validator3 } = await loadFixture(deployValidatorSyncFixture);

      const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      const blockNumber = 1000;
      const timestamp = Math.floor(Date.now() / 1000);

      // Not confirmed initially
      expect(await validatorSync.isStateConfirmed(stateRoot, blockNumber)).to.be.false;

      // Submit from three validators to reach consensus
      await validatorSync.connect(validator1).submitStateUpdate(stateRoot, blockNumber, timestamp);
      await validatorSync.connect(validator2).submitStateUpdate(stateRoot, blockNumber, timestamp);
      await validatorSync.connect(validator3).submitStateUpdate(stateRoot, blockNumber, timestamp);

      // Now confirmed
      expect(await validatorSync.isStateConfirmed(stateRoot, blockNumber)).to.be.true;
    });

    it("Should get pending state updates", async function () {
      const { validatorSync, validator1 } = await loadFixture(deployValidatorSyncFixture);

      const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("STATE_ROOT_1"));
      const blockNumber = 1000;
      const timestamp = Math.floor(Date.now() / 1000);

      // Submit but don't reach consensus
      await validatorSync.connect(validator1).submitStateUpdate(stateRoot, blockNumber, timestamp);

      const pendingCount = await validatorSync.getPendingStateCount(blockNumber);
      expect(pendingCount).to.equal(1);
    });
  });
});