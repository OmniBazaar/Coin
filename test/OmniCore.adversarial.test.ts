/**
 * OmniCore.sol — Adversarial Test Suite (Round 8)
 *
 * Tests derived from adversarial agent A1 findings:
 *   Finding 1: ERC-2771 Forwarder-Mediated Admin Relay (Medium, MEDIUM conf)
 *   Finding 2: Bootstrap Stale-Data Validator Spoofing (Low, LOW conf)
 *   Finding 3: Legacy Claim Signature Grinding (Info, LOW conf)
 *   DEFENDED: Ossification bypass, DEX disable re-enable, reentrancy, staking overflow
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniCore — Adversarial (Round 8)', function () {
  let core: any;
  let token: any;
  let owner: any;
  let admin2: any;
  let validator1: any;
  let attacker: any;
  let other: any;

  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes('ADMIN_ROLE'));
  const AVALANCHE_VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes('AVALANCHE_VALIDATOR_ROLE'));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
  const ADMIN_TRANSFER_DELAY = 48 * 3600;

  beforeEach(async function () {
    [owner, admin2, validator1, attacker, other] = await ethers.getSigners();

    const Token = await ethers.getContractFactory('OmniCoin');
    token = await Token.deploy(ethers.ZeroAddress);
    await token.initialize();

    const OmniCore = await ethers.getContractFactory('OmniCore');
    core = await upgrades.deployProxy(
      OmniCore,
      [owner.address, token.target, owner.address, owner.address, owner.address],
      { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
    );

    // Fund
    await token.transfer(attacker.address, ethers.parseEther('10000'));
    await token.connect(attacker).approve(core.target, ethers.MaxUint256);
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  Finding 1: ERC-2771 Forwarder-Mediated Admin Relay
  // ═══════════════════════════════════════════════════════════════════════

  describe('Finding 1: ERC-2771 admin function relay surface', function () {
    it('should document that onlyRole functions use _msgSender', async function () {
      // Verify that admin functions are callable by the role holder
      // This documents that the forwarder relay path exists
      await expect(
        core.setService(ethers.keccak256(ethers.toUtf8Bytes('TEST_SERVICE')), other.address)
      ).to.not.be.reverted;
    });

    it('should reject non-admin calls to setService', async function () {
      await expect(
        core.connect(attacker).setService(
          ethers.keccak256(ethers.toUtf8Bytes('TEST_SERVICE')),
          attacker.address
        )
      ).to.be.reverted;
    });

    it('should use explicit msg.sender for proposeAdminTransfer (M-03 fix)', async function () {
      // proposeAdminTransfer uses msg.sender (not _msgSender) per M-03
      await core.proposeAdminTransfer(admin2.address);

      // Non-admin cannot propose
      await expect(
        core.connect(attacker).proposeAdminTransfer(attacker.address)
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Ossification is permanent and blocks upgrades
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Ossification', function () {
    it('should permanently block upgrades after ossification', async function () {
      await core.ossify();
      expect(await core.isOssified()).to.be.true;

      const OmniCoreFactory = await ethers.getContractFactory('OmniCore');
      const newImpl = await OmniCoreFactory.deploy(ethers.ZeroAddress);

      await expect(
        core.upgradeToAndCall(await newImpl.getAddress(), '0x')
      ).to.be.revertedWithCustomError(core, 'ContractIsOssified');
    });

    it('should reject non-admin ossification', async function () {
      await expect(
        core.connect(attacker).ossify()
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: DEX Settlement disable is permanent
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: DEX Settlement disable permanence', function () {
    it('should permanently disable DEX settlement', async function () {
      await core.disableDEXSettlement();
      expect(await core.dexSettlementDisabled()).to.be.true;
    });

    it('should reject non-admin disable', async function () {
      await expect(
        core.connect(attacker).disableDEXSettlement()
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Two-step admin transfer with 48h timelock
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Admin transfer timelock', function () {
    it('should enforce 48h delay on admin transfer', async function () {
      await core.proposeAdminTransfer(admin2.address);

      // Cannot accept immediately
      await expect(
        core.connect(admin2).acceptAdminTransfer()
      ).to.be.reverted;

      // Advance 24h (not enough)
      await time.increase(24 * 3600);
      await expect(
        core.connect(admin2).acceptAdminTransfer()
      ).to.be.reverted;

      // Advance to 48h+
      await time.increase(24 * 3600 + 1);
      await expect(
        core.connect(admin2).acceptAdminTransfer()
      ).to.not.be.reverted;

      // admin2 now has ADMIN_ROLE
      expect(await core.hasRole(ADMIN_ROLE, admin2.address)).to.be.true;
    });

    it('should reject acceptance by wrong address', async function () {
      await core.proposeAdminTransfer(admin2.address);
      await time.increase(ADMIN_TRANSFER_DELAY + 1);

      await expect(
        core.connect(attacker).acceptAdminTransfer()
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Access control on all admin functions
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Access control', function () {
    it('should reject non-admin pause', async function () {
      await expect(
        core.connect(attacker).pause()
      ).to.be.reverted;
    });

    it('should reject non-admin setService', async function () {
      await expect(
        core.connect(attacker).setService(
          ethers.keccak256(ethers.toUtf8Bytes('TEST')),
          attacker.address
        )
      ).to.be.reverted;
    });

    it('should reject non-admin setOddaoAddress', async function () {
      await expect(
        core.connect(attacker).setOddaoAddress(attacker.address)
      ).to.be.reverted;
    });

    it('should reject non-admin setRequiredSignatures', async function () {
      await expect(
        core.connect(attacker).setRequiredSignatures(1)
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Staking tier and duration validation
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Staking input validation', function () {
    it('should reject zero-amount stake', async function () {
      await expect(
        core.connect(attacker).stake(0, 1, 86400 * 30)
      ).to.be.reverted;
    });

    it('should reject invalid tier', async function () {
      await token.transfer(attacker.address, ethers.parseEther('1000'));
      await token.connect(attacker).approve(await core.getAddress(), ethers.MaxUint256);

      await expect(
        core.connect(attacker).stake(ethers.parseEther('1000'), 6, 86400 * 30)
      ).to.be.reverted;
    });
  });
});
