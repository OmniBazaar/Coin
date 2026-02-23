/**
 * @file OmniValidatorManager.test.js
 * @description Tests for ultra-lean OmniValidatorManager contract
 */

const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('OmniValidatorManager', function () {
  let validatorManager;
  let qualificationOracle;
  let owner, verifier, validator1, validator2, validator3, user1;

  // Sample validator data
  let nodeID1, blsPublicKey1;
  let nodeID2, blsPublicKey2;
  let nodeID3, blsPublicKey3;

  beforeEach(async function () {
    [owner, verifier, validator1, validator2, validator3, user1] =
      await ethers.getSigners();

    // Generate sample validator data
    nodeID1 = ethers.hexlify(ethers.randomBytes(20));
    blsPublicKey1 = ethers.hexlify(ethers.randomBytes(48));

    nodeID2 = ethers.hexlify(ethers.randomBytes(20));
    blsPublicKey2 = ethers.hexlify(ethers.randomBytes(48));

    nodeID3 = ethers.hexlify(ethers.randomBytes(20));
    blsPublicKey3 = ethers.hexlify(ethers.randomBytes(48));

    // Deploy QualificationOracle (UUPS proxy)
    const OracleFactory = await ethers.getContractFactory('QualificationOracle');
    qualificationOracle = await upgrades.deployProxy(
      OracleFactory,
      [verifier.address],
      { kind: 'uups' }
    );

    await qualificationOracle.waitForDeployment();

    // Deploy OmniValidatorManager (UUPS proxy)
    const ValidatorManagerFactory = await ethers.getContractFactory(
      'OmniValidatorManager'
    );
    validatorManager = await upgrades.deployProxy(
      ValidatorManagerFactory,
      [await qualificationOracle.getAddress()],
      { kind: 'uups' }
    );

    await validatorManager.waitForDeployment();
  });

  describe('Deployment', function () {
    it('Should set correct oracle address', async function () {
      expect(await validatorManager.qualificationOracle()).to.equal(
        await qualificationOracle.getAddress()
      );
    });

    it('Should have zero active validators initially', async function () {
      expect(await validatorManager.activeValidatorCount()).to.equal(0);
    });

    it('Should have constant weight of 100', async function () {
      expect(await validatorManager.VALIDATOR_WEIGHT()).to.equal(100);
    });
  });

  describe('Permissionless Validator Registration', function () {
    beforeEach(async function () {
      // Qualify validator1 and validator2
      await qualificationOracle.connect(verifier).setQualified(validator1.address);
      await qualificationOracle.connect(verifier).setQualified(validator2.address);

      // Do NOT qualify validator3
    });

    it('Should allow qualified user to register', async function () {
      await expect(
        validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1)
      )
        .to.emit(validatorManager, 'ValidatorRegistered')
        .withArgs(validator1.address, nodeID1, blsPublicKey1);

      const info = await validatorManager.getValidator(validator1.address);
      expect(info.owner).to.equal(validator1.address);
      expect(info.nodeID).to.equal(nodeID1);
      expect(info.blsPublicKey).to.equal(blsPublicKey1);
      expect(info.active).to.be.true;
    });

    it('Should reject unqualified user', async function () {
      await expect(
        validatorManager.connect(validator3).registerValidator(nodeID3, blsPublicKey3)
      ).to.be.revertedWithCustomError(validatorManager, 'NotQualified');
    });

    it('Should reject duplicate registration', async function () {
      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);

      await expect(
        validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1)
      ).to.be.revertedWithCustomError(validatorManager, 'ValidatorAlreadyRegistered');
    });

    it('Should reject invalid nodeID', async function () {
      await expect(
        validatorManager.connect(validator1).registerValidator('0x', blsPublicKey1)
      ).to.be.revertedWithCustomError(validatorManager, 'InvalidNodeID');
    });

    it('Should reject invalid BLS public key', async function () {
      const invalidBLS = ethers.hexlify(ethers.randomBytes(32)); // Wrong length (needs 48)

      await expect(
        validatorManager.connect(validator1).registerValidator(nodeID1, invalidBLS)
      ).to.be.revertedWithCustomError(validatorManager, 'InvalidBLSPublicKey');
    });

    it('Should increment active validator count', async function () {
      expect(await validatorManager.activeValidatorCount()).to.equal(0);

      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);
      expect(await validatorManager.activeValidatorCount()).to.equal(1);

      await validatorManager.connect(validator2).registerValidator(nodeID2, blsPublicKey2);
      expect(await validatorManager.activeValidatorCount()).to.equal(2);
    });

    it('Should allow re-registration after disqualification and requalification', async function () {
      // Register
      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);

      // Deactivate
      await validatorManager.deactivateValidator(validator1.address);

      // Disqualify
      await qualificationOracle
        .connect(verifier)
        .setDisqualified(validator1.address, ethers.ZeroHash);

      // Try to reactivate (should fail - not qualified)
      await expect(
        validatorManager.reactivateValidator(validator1.address)
      ).to.be.revertedWithCustomError(validatorManager, 'NotQualified');

      // Requalify
      await qualificationOracle.connect(verifier).setQualified(validator1.address);

      // Reactivate (should succeed)
      await expect(validatorManager.reactivateValidator(validator1.address))
        .to.emit(validatorManager, 'ValidatorActivated')
        .withArgs(validator1.address);
    });
  });

  describe('Equal Consensus Weights (Ultra-Lean)', function () {
    beforeEach(async function () {
      // Qualify and register multiple validators
      await qualificationOracle.connect(verifier).batchSetQualified([
        validator1.address,
        validator2.address,
        validator3.address,
      ]);

      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);
      await validatorManager.connect(validator2).registerValidator(nodeID2, blsPublicKey2);
      await validatorManager.connect(validator3).registerValidator(nodeID3, blsPublicKey3);
    });

    it('Should assign equal consensus weight to all validators', async function () {
      const EXPECTED_WEIGHT = 100n;

      expect(await validatorManager.getValidatorWeight(validator1.address)).to.equal(
        EXPECTED_WEIGHT
      );
      expect(await validatorManager.getValidatorWeight(validator2.address)).to.equal(
        EXPECTED_WEIGHT
      );
      expect(await validatorManager.getValidatorWeight(validator3.address)).to.equal(
        EXPECTED_WEIGHT
      );
    });

    it('Should maintain equal weights even after deactivation', async function () {
      await validatorManager.deactivateValidator(validator1.address);

      // Weight should still be 100 (constant)
      expect(await validatorManager.getValidatorWeight(validator1.address)).to.equal(100n);
    });

    it('Should return weight for any address (pure function)', async function () {
      // Even unregistered addresses return weight (it's a constant)
      expect(await validatorManager.getValidatorWeight(user1.address)).to.equal(100n);
    });
  });

  describe('Validator Deactivation/Reactivation', function () {
    beforeEach(async function () {
      await qualificationOracle.connect(verifier).setQualified(validator1.address);
      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);
    });

    it('Should allow owner to deactivate validator', async function () {
      await expect(validatorManager.deactivateValidator(validator1.address))
        .to.emit(validatorManager, 'ValidatorDeactivated')
        .withArgs(validator1.address);

      const info = await validatorManager.getValidator(validator1.address);
      expect(info.active).to.be.false;
      expect(await validatorManager.activeValidatorCount()).to.equal(0);
    });

    it('Should allow owner to reactivate validator if still qualified', async function () {
      await validatorManager.deactivateValidator(validator1.address);

      await expect(validatorManager.reactivateValidator(validator1.address))
        .to.emit(validatorManager, 'ValidatorActivated')
        .withArgs(validator1.address);

      const info = await validatorManager.getValidator(validator1.address);
      expect(info.active).to.be.true;
      expect(await validatorManager.activeValidatorCount()).to.equal(1);
    });

    it('Should reject reactivation if disqualified', async function () {
      await validatorManager.deactivateValidator(validator1.address);

      // Disqualify
      await qualificationOracle
        .connect(verifier)
        .setDisqualified(validator1.address, ethers.ZeroHash);

      await expect(
        validatorManager.reactivateValidator(validator1.address)
      ).to.be.revertedWithCustomError(validatorManager, 'NotQualified');
    });

    it('Should not allow non-owner to deactivate', async function () {
      await expect(
        validatorManager.connect(validator2).deactivateValidator(validator1.address)
      ).to.be.revertedWithCustomError(validatorManager, 'OwnableUnauthorizedAccount');
    });

    it('Should not allow non-owner to reactivate', async function () {
      await validatorManager.deactivateValidator(validator1.address);

      await expect(
        validatorManager.connect(validator2).reactivateValidator(validator1.address)
      ).to.be.revertedWithCustomError(validatorManager, 'OwnableUnauthorizedAccount');
    });
  });

  describe('Validator Queries', function () {
    beforeEach(async function () {
      await qualificationOracle.connect(verifier).batchSetQualified([
        validator1.address,
        validator2.address,
      ]);

      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);
      await validatorManager.connect(validator2).registerValidator(nodeID2, blsPublicKey2);
    });

    it('Should return validator by nodeID', async function () {
      const validator = await validatorManager.getValidatorByNodeID(nodeID1);
      expect(validator).to.equal(validator1.address);
    });

    it('Should return all active validators', async function () {
      const activeValidators = await validatorManager.getActiveValidators();
      expect(activeValidators.length).to.equal(2);
      expect(activeValidators).to.include(validator1.address);
      expect(activeValidators).to.include(validator2.address);
    });

    it('Should correctly identify active validators', async function () {
      expect(await validatorManager.isActiveValidator(validator1.address)).to.be.true;
      expect(await validatorManager.isActiveValidator(validator2.address)).to.be.true;
      expect(await validatorManager.isActiveValidator(user1.address)).to.be.false;
    });

    it('Should return correct total count', async function () {
      expect(await validatorManager.getTotalValidatorCount()).to.equal(2);

      // Deactivate one
      await validatorManager.deactivateValidator(validator1.address);

      // Total count unchanged, but active count reduced
      expect(await validatorManager.getTotalValidatorCount()).to.equal(2);
      expect(await validatorManager.activeValidatorCount()).to.equal(1);
    });

    it('Should return empty validator info for unregistered address', async function () {
      const info = await validatorManager.getValidator(user1.address);
      expect(info.owner).to.equal(ethers.ZeroAddress);
      expect(info.active).to.be.false;
    });
  });

  describe('Admin Functions', function () {
    it('Should allow owner to change oracle', async function () {
      const newOracle = user1.address;

      await expect(validatorManager.setQualificationOracle(newOracle))
        .to.emit(validatorManager, 'QualificationOracleUpdated')
        .withArgs(await qualificationOracle.getAddress(), newOracle);

      expect(await validatorManager.qualificationOracle()).to.equal(newOracle);
    });

    it('Should not allow non-owner to change oracle', async function () {
      await expect(
        validatorManager.connect(validator1).setQualificationOracle(user1.address)
      ).to.be.revertedWithCustomError(validatorManager, 'OwnableUnauthorizedAccount');
    });
  });

  describe('UUPS Upgradeability', function () {
    it('Should allow owner to upgrade', async function () {
      const ValidatorManagerV2Factory = await ethers.getContractFactory(
        'OmniValidatorManager'
      );

      await expect(
        upgrades.upgradeProxy(
          await validatorManager.getAddress(),
          ValidatorManagerV2Factory
        )
      ).to.not.be.reverted;
    });

    it('Should not allow non-owner to upgrade', async function () {
      const ValidatorManagerV2Factory = await ethers.getContractFactory(
        'OmniValidatorManager',
        validator1
      );

      await expect(
        upgrades.upgradeProxy(
          await validatorManager.getAddress(),
          ValidatorManagerV2Factory
        )
      ).to.be.revertedWithCustomError(validatorManager, 'OwnableUnauthorizedAccount');
    });

    it('Should preserve validator data after upgrade', async function () {
      // Register validators
      await qualificationOracle.connect(verifier).setQualified(validator1.address);
      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);

      // Upgrade
      const ValidatorManagerV2Factory = await ethers.getContractFactory(
        'OmniValidatorManager'
      );
      const upgraded = await upgrades.upgradeProxy(
        await validatorManager.getAddress(),
        ValidatorManagerV2Factory
      );

      // Data should be preserved
      const info = await upgraded.getValidator(validator1.address);
      expect(info.owner).to.equal(validator1.address);
      expect(info.active).to.be.true;
      expect(await upgraded.activeValidatorCount()).to.equal(1);
    });
  });

  describe('Gas Efficiency (Ultra-Lean)', function () {
    beforeEach(async function () {
      await qualificationOracle.connect(verifier).setQualified(validator1.address);
    });

    it('Should store minimal data on-chain', async function () {
      await validatorManager.connect(validator1).registerValidator(nodeID1, blsPublicKey1);

      const info = await validatorManager.getValidator(validator1.address);

      // Verify minimal storage (ultra-lean)
      expect(info.nodeID).to.equal(nodeID1);
      expect(info.blsPublicKey).to.equal(blsPublicKey1);
      expect(info.owner).to.equal(validator1.address);
      expect(info.active).to.be.true;
      expect(info.registeredAt).to.be.gt(0);

      // NO PoP score stored (ultra-lean architecture)
      expect(info.popScore).to.be.undefined;
    });
  });
});
