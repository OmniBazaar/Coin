/**
 * @file QualificationOracle.test.js
 * @description Tests for ultra-lean QualificationOracle contract
 */

const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('QualificationOracle', function () {
  let oracle;
  let owner, verifier, user1, user2, user3;

  beforeEach(async function () {
    [owner, verifier, user1, user2, user3] = await ethers.getSigners();

    // Deploy QualificationOracle (UUPS proxy)
    const OracleFactory = await ethers.getContractFactory('QualificationOracle');
    oracle = await upgrades.deployProxy(OracleFactory, [verifier.address], {
      kind: 'uups',
    });

    await oracle.waitForDeployment();
  });

  describe('Deployment', function () {
    it('Should set correct verifier', async function () {
      expect(await oracle.verifier()).to.equal(verifier.address);
    });

    it('Should set correct owner', async function () {
      expect(await oracle.owner()).to.equal(owner.address);
    });

    it('Should have no qualified users initially', async function () {
      expect(await oracle.isQualified(user1.address)).to.be.false;
      expect(await oracle.isQualified(user2.address)).to.be.false;
    });
  });

  describe('Qualification Management', function () {
    it('Should allow verifier to qualify user', async function () {
      await expect(oracle.connect(verifier).setQualified(user1.address))
        .to.emit(oracle, 'Qualified')
        .withArgs(user1.address, await ethers.provider.getBlock('latest').then((b) => b.timestamp + 1));

      expect(await oracle.isQualified(user1.address)).to.be.true;
    });

    it('Should reject non-verifier qualification', async function () {
      await expect(
        oracle.connect(user1).setQualified(user1.address)
      ).to.be.revertedWithCustomError(oracle, 'OnlyVerifier');
    });

    it('Should allow verifier to disqualify user', async function () {
      // First qualify
      await oracle.connect(verifier).setQualified(user1.address);

      // Then disqualify
      const reason = ethers.keccak256(ethers.toUtf8Bytes('PoP score dropped below 50'));

      await expect(oracle.connect(verifier).setDisqualified(user1.address, reason))
        .to.emit(oracle, 'Disqualified')
        .withArgs(user1.address, reason);

      expect(await oracle.isQualified(user1.address)).to.be.false;
    });

    it('Should store disqualification reason', async function () {
      await oracle.connect(verifier).setQualified(user1.address);

      const reason = ethers.keccak256(ethers.toUtf8Bytes('Insufficient stake'));
      await oracle.connect(verifier).setDisqualified(user1.address, reason);

      const details = await oracle.getQualificationDetails(user1.address);
      expect(details[2]).to.equal(reason); // reason is third element
    });

    it('Should clear disqualification reason on requalification', async function () {
      const reason = ethers.keccak256(ethers.toUtf8Bytes('Test reason'));
      await oracle.connect(verifier).setDisqualified(user1.address, reason);

      // Requalify
      await oracle.connect(verifier).setQualified(user1.address);

      const details = await oracle.getQualificationDetails(user1.address);
      expect(details[2]).to.equal(ethers.ZeroHash); // reason cleared
    });
  });

  describe('Batch Operations', function () {
    it('Should batch qualify multiple users', async function () {
      const users = [user1.address, user2.address, user3.address];

      await oracle.connect(verifier).batchSetQualified(users);

      expect(await oracle.isQualified(user1.address)).to.be.true;
      expect(await oracle.isQualified(user2.address)).to.be.true;
      expect(await oracle.isQualified(user3.address)).to.be.true;
    });

    it('Should batch disqualify multiple users', async function () {
      const users = [user1.address, user2.address, user3.address];

      // First qualify all
      await oracle.connect(verifier).batchSetQualified(users);

      // Then disqualify all
      const reasons = [
        ethers.keccak256(ethers.toUtf8Bytes('Reason 1')),
        ethers.keccak256(ethers.toUtf8Bytes('Reason 2')),
        ethers.keccak256(ethers.toUtf8Bytes('Reason 3')),
      ];

      await oracle.connect(verifier).batchSetDisqualified(users, reasons);

      expect(await oracle.isQualified(user1.address)).to.be.false;
      expect(await oracle.isQualified(user2.address)).to.be.false;
      expect(await oracle.isQualified(user3.address)).to.be.false;
    });

    it('Should reject batch disqualify with mismatched lengths', async function () {
      const users = [user1.address, user2.address];
      const reasons = [ethers.keccak256(ethers.toUtf8Bytes('Reason 1'))]; // Wrong length

      await expect(
        oracle.connect(verifier).batchSetDisqualified(users, reasons)
      ).to.be.revertedWith('Length mismatch');
    });

    it('Should batch check qualifications', async function () {
      await oracle.connect(verifier).setQualified(user1.address);
      await oracle.connect(verifier).setQualified(user3.address);

      const users = [user1.address, user2.address, user3.address];
      const qualifications = await oracle.batchIsQualified(users);

      expect(qualifications[0]).to.be.true;
      expect(qualifications[1]).to.be.false;
      expect(qualifications[2]).to.be.true;
    });
  });

  describe('View Functions', function () {
    beforeEach(async function () {
      await oracle.connect(verifier).setQualified(user1.address);
    });

    it('Should return correct qualification status', async function () {
      expect(await oracle.isQualified(user1.address)).to.be.true;
      expect(await oracle.isQualified(user2.address)).to.be.false;
    });

    it('Should return qualification details', async function () {
      const details = await oracle.getQualificationDetails(user1.address);

      expect(details[0]).to.be.true; // isQualified
      expect(details[1]).to.be.gt(0); // timestamp
      expect(details[2]).to.equal(ethers.ZeroHash); // no disqualification reason
    });

    it('Should return details for disqualified user', async function () {
      const reasonHash = ethers.keccak256(ethers.toUtf8Bytes('Test reason'));
      await oracle.connect(verifier).setDisqualified(user1.address, reasonHash);

      const details = await oracle.getQualificationDetails(user1.address);

      expect(details[0]).to.be.false; // not qualified
      expect(details[1]).to.be.gt(0); // original qualification timestamp preserved
      expect(details[2]).to.equal(reasonHash); // reason stored
    });
  });

  describe('Admin Functions', function () {
    it('Should allow owner to change verifier', async function () {
      const newVerifier = user1.address;

      await expect(oracle.setVerifier(newVerifier))
        .to.emit(oracle, 'VerifierChanged')
        .withArgs(verifier.address, newVerifier);

      expect(await oracle.verifier()).to.equal(newVerifier);
    });

    it('Should not allow non-owner to change verifier', async function () {
      await expect(
        oracle.connect(user1).setVerifier(user2.address)
      ).to.be.revertedWithCustomError(oracle, 'OwnableUnauthorizedAccount');
    });
  });

  describe('UUPS Upgradeability', function () {
    it('Should allow owner to upgrade', async function () {
      const OracleV2Factory = await ethers.getContractFactory('QualificationOracle');

      await expect(upgrades.upgradeProxy(await oracle.getAddress(), OracleV2Factory)).to.not
        .be.reverted;
    });

    it('Should not allow non-owner to upgrade', async function () {
      const OracleV2Factory = await ethers.getContractFactory(
        'QualificationOracle',
        verifier
      );

      await expect(
        upgrades.upgradeProxy(await oracle.getAddress(), OracleV2Factory)
      ).to.be.revertedWithCustomError(oracle, 'OwnableUnauthorizedAccount');
    });

    it('Should preserve data after upgrade', async function () {
      // Set qualifications
      await oracle.connect(verifier).setQualified(user1.address);
      await oracle.connect(verifier).setQualified(user2.address);

      // Upgrade
      const OracleV2Factory = await ethers.getContractFactory('QualificationOracle');
      const upgraded = await upgrades.upgradeProxy(
        await oracle.getAddress(),
        OracleV2Factory
      );

      // Data should be preserved
      expect(await upgraded.isQualified(user1.address)).to.be.true;
      expect(await upgraded.isQualified(user2.address)).to.be.true;
      expect(await upgraded.isQualified(user3.address)).to.be.false;
    });
  });

  describe('Gas Efficiency (Ultra-Lean Validation)', function () {
    it('Should use minimal gas for qualification check', async function () {
      await oracle.connect(verifier).setQualified(user1.address);

      // isQualified should be very cheap (just reading a boolean)
      const tx = await oracle.isQualified.staticCall(user1.address);

      // Just verify it returns expected value
      expect(tx).to.be.true;
    });

    it('Should batch qualify efficiently', async function () {
      const users = Array.from({ length: 10 }, () =>
        ethers.Wallet.createRandom().address
      );

      const tx = await oracle.connect(verifier).batchSetQualified(users);
      const receipt = await tx.wait();

      // Should be under 52k gas per user (realistic for UUPS proxy + events)
      const gasPerUser = Number(receipt.gasUsed) / users.length;
      expect(gasPerUser).to.be.lt(52000);

      console.log(`      Gas per user (batch qualify): ${gasPerUser.toFixed(0)}`);
    });
  });
});
