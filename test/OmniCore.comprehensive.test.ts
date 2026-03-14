/**
 * OmniCore.sol — Comprehensive Test Suite (Round 8)
 *
 * Supplements the existing 55-test OmniCore.test.js with ~80 additional tests
 * covering gaps identified during Round 8 adversarial review:
 *
 * 1. Deployment + initialization (zero-address guards, role setup)
 * 2. Service registry (set/get/override/access control)
 * 3. Staking (tier validation, duration validation, checkpoints)
 * 4. Two-step admin transfer (propose/accept/cancel, 48h timelock, role revocation)
 * 5. Legacy migration (batch register, claim with M-of-N sigs, nonce replay)
 * 6. DEX settlement deprecation (disable permanently, cannot re-enable)
 * 7. UUPS upgrade + ossification
 * 8. Provisioner role
 * 9. Fee address management
 * 10. Adversarial edge cases
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniCore — Comprehensive', function () {
  let core: any;
  let token: any;
  let owner: any;
  let admin2: any;
  let validator1: any;
  let validator2: any;
  let validator3: any;
  let staker1: any;
  let staker2: any;
  let protocolTreasury: any;
  let oddao: any;
  let stakingPool: any;
  let provisioner: any;

  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes('ADMIN_ROLE'));
  const AVALANCHE_VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes('AVALANCHE_VALIDATOR_ROLE'));
  const PROVISIONER_ROLE = ethers.keccak256(ethers.toUtf8Bytes('PROVISIONER_ROLE'));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

  const DAY = 86400;
  const THIRTY_DAYS = 30 * DAY;
  const ONE_EIGHTY_DAYS = 180 * DAY;
  const SEVEN_THIRTY_DAYS = 730 * DAY;
  const ADMIN_TRANSFER_DELAY = 48 * 3600; // 48 hours

  beforeEach(async function () {
    [owner, admin2, validator1, validator2, validator3, staker1, staker2,
     protocolTreasury, oddao, stakingPool, provisioner] = await ethers.getSigners();

    // Deploy OmniCoin token
    const Token = await ethers.getContractFactory('OmniCoin');
    token = await Token.deploy(ethers.ZeroAddress);
    await token.initialize();

    // Deploy upgradeable OmniCore using proxy
    const OmniCore = await ethers.getContractFactory('OmniCore');
    core = await upgrades.deployProxy(
      OmniCore,
      [owner.address, token.target, oddao.address, stakingPool.address, protocolTreasury.address],
      { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
    );

    // Fund accounts
    await token.transfer(staker1.address, ethers.parseEther('10000'));
    await token.transfer(staker2.address, ethers.parseEther('10000'));
    await token.transfer(validator1.address, ethers.parseEther('10000'));
    await token.transfer(core.target, ethers.parseEther('1000000'));

    // Approve core
    await token.connect(staker1).approve(core.target, ethers.MaxUint256);
    await token.connect(staker2).approve(core.target, ethers.MaxUint256);
    await token.connect(validator1).approve(core.target, ethers.MaxUint256);
  });

  // =========================================================================
  // 1. DEPLOYMENT + INITIALIZATION
  // =========================================================================

  describe('Deployment & Initialization Guards', function () {
    it('should revert initialize with zero admin address', async function () {
      const OmniCore = await ethers.getContractFactory('OmniCore');
      await expect(
        upgrades.deployProxy(
          OmniCore,
          [ethers.ZeroAddress, token.target, oddao.address, stakingPool.address, protocolTreasury.address],
          { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should revert initialize with zero token address', async function () {
      const OmniCore = await ethers.getContractFactory('OmniCore');
      await expect(
        upgrades.deployProxy(
          OmniCore,
          [owner.address, ethers.ZeroAddress, oddao.address, stakingPool.address, protocolTreasury.address],
          { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should revert initialize with zero oddao address', async function () {
      const OmniCore = await ethers.getContractFactory('OmniCore');
      await expect(
        upgrades.deployProxy(
          OmniCore,
          [owner.address, token.target, ethers.ZeroAddress, stakingPool.address, protocolTreasury.address],
          { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should revert initialize with zero staking pool address', async function () {
      const OmniCore = await ethers.getContractFactory('OmniCore');
      await expect(
        upgrades.deployProxy(
          OmniCore,
          [owner.address, token.target, oddao.address, ethers.ZeroAddress, protocolTreasury.address],
          { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should revert initialize with zero protocol treasury address', async function () {
      const OmniCore = await ethers.getContractFactory('OmniCore');
      await expect(
        upgrades.deployProxy(
          OmniCore,
          [owner.address, token.target, oddao.address, stakingPool.address, ethers.ZeroAddress],
          { initializer: 'initialize', constructorArgs: [ethers.ZeroAddress] }
        )
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should grant DEFAULT_ADMIN_ROLE and ADMIN_ROLE to admin', async function () {
      expect(await core.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
      expect(await core.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
    });

    it('should set fee recipient addresses correctly', async function () {
      expect(await core.oddaoAddress()).to.equal(oddao.address);
      expect(await core.stakingPoolAddress()).to.equal(stakingPool.address);
      expect(await core.protocolTreasuryAddress()).to.equal(protocolTreasury.address);
    });
  });

  // =========================================================================
  // 2. SERVICE REGISTRY
  // =========================================================================

  describe('Service Registry — Extended', function () {
    const MARKETPLACE_ID = ethers.id('marketplace');

    it('should revert setService with zero address', async function () {
      await expect(
        core.connect(owner).setService(MARKETPLACE_ID, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should allow overwriting a service address', async function () {
      const addr1 = validator1.address;
      const addr2 = validator2.address;
      await core.connect(owner).setService(MARKETPLACE_ID, addr1);
      await core.connect(owner).setService(MARKETPLACE_ID, addr2);
      expect(await core.getService(MARKETPLACE_ID)).to.equal(addr2);
    });

    it('should return zero address for unregistered service', async function () {
      expect(await core.getService(ethers.id('nonexistent'))).to.equal(ethers.ZeroAddress);
    });

    it('should prevent non-admin from setting services', async function () {
      await expect(
        core.connect(staker1).setService(MARKETPLACE_ID, validator1.address)
      ).to.be.reverted;
    });

    it('should emit ServiceUpdated with correct timestamp', async function () {
      const tx = await core.connect(owner).setService(MARKETPLACE_ID, validator1.address);
      const block = await ethers.provider.getBlock(tx.blockNumber);
      await expect(tx)
        .to.emit(core, 'ServiceUpdated')
        .withArgs(MARKETPLACE_ID, validator1.address, block!.timestamp);
    });

    it('should store multiple services independently', async function () {
      const BRIDGE_ID = ethers.id('bridge');
      await core.connect(owner).setService(MARKETPLACE_ID, validator1.address);
      await core.connect(owner).setService(BRIDGE_ID, validator2.address);
      expect(await core.getService(MARKETPLACE_ID)).to.equal(validator1.address);
      expect(await core.getService(BRIDGE_ID)).to.equal(validator2.address);
    });
  });

  // =========================================================================
  // 3. STAKING — Tier & Duration Validation
  // =========================================================================

  describe('Staking — Tier Validation', function () {
    it('should accept tier 1 with exactly 1 XOM', async function () {
      await core.connect(staker1).stake(ethers.parseEther('1'), 1, 0);
      const s = await core.stakes(staker1.address);
      expect(s.tier).to.equal(1);
      expect(s.active).to.be.true;
    });

    it('should accept tier 1 with 999999 XOM', async function () {
      await token.transfer(staker1.address, ethers.parseEther('990000'));
      await core.connect(staker1).stake(ethers.parseEther('999999'), 1, 0);
      const s = await core.stakes(staker1.address);
      expect(s.tier).to.equal(1);
    });

    it('should reject tier 2 with 999999 XOM (below 1M threshold)', async function () {
      await token.transfer(staker1.address, ethers.parseEther('990000'));
      await expect(
        core.connect(staker1).stake(ethers.parseEther('999999'), 2, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidStakingTier');
    });

    it('should accept tier 2 with exactly 1M XOM', async function () {
      await token.transfer(staker1.address, ethers.parseEther('1000000'));
      await token.connect(staker1).approve(core.target, ethers.MaxUint256);
      await core.connect(staker1).stake(ethers.parseEther('1000000'), 2, 0);
      const s = await core.stakes(staker1.address);
      expect(s.tier).to.equal(2);
    });

    it('should reject tier 3 with 9999999 XOM', async function () {
      await token.transfer(staker1.address, ethers.parseEther('10000000'));
      await token.connect(staker1).approve(core.target, ethers.MaxUint256);
      await expect(
        core.connect(staker1).stake(ethers.parseEther('9999999'), 3, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidStakingTier');
    });

    it('should reject tier 0', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 0, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidStakingTier');
    });

    it('should reject tier 6', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 6, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidStakingTier');
    });

    it('should reject tier 255 (max uint8 value)', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 255, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidStakingTier');
    });
  });

  describe('Staking — Duration Validation', function () {
    it('should accept duration 0 (no lock)', async function () {
      await core.connect(staker1).stake(ethers.parseEther('100'), 1, 0);
      const s = await core.stakes(staker1.address);
      expect(s.duration).to.equal(0);
    });

    it('should accept duration 30 days', async function () {
      await core.connect(staker1).stake(ethers.parseEther('100'), 1, THIRTY_DAYS);
      const s = await core.stakes(staker1.address);
      expect(s.duration).to.equal(THIRTY_DAYS);
    });

    it('should accept duration 180 days', async function () {
      await core.connect(staker1).stake(ethers.parseEther('100'), 1, ONE_EIGHTY_DAYS);
      const s = await core.stakes(staker1.address);
      expect(s.duration).to.equal(ONE_EIGHTY_DAYS);
    });

    it('should accept duration 730 days', async function () {
      await core.connect(staker1).stake(ethers.parseEther('100'), 1, SEVEN_THIRTY_DAYS);
      const s = await core.stakes(staker1.address);
      expect(s.duration).to.equal(SEVEN_THIRTY_DAYS);
    });

    it('should reject duration 1 day', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 1, DAY)
      ).to.be.revertedWithCustomError(core, 'InvalidDuration');
    });

    it('should reject duration 60 days', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 1, 60 * DAY)
      ).to.be.revertedWithCustomError(core, 'InvalidDuration');
    });

    it('should reject duration 365 days', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 1, 365 * DAY)
      ).to.be.revertedWithCustomError(core, 'InvalidDuration');
    });

    it('should reject duration 29 days (one second short of 30)', async function () {
      await expect(
        core.connect(staker1).stake(ethers.parseEther('100'), 1, THIRTY_DAYS - 1)
      ).to.be.revertedWithCustomError(core, 'InvalidDuration');
    });
  });

  describe('Staking — Checkpoints', function () {
    it('should write checkpoint on stake', async function () {
      await core.connect(staker1).stake(ethers.parseEther('1000'), 1, 0);
      const bn = await ethers.provider.getBlockNumber();
      const stakedAt = await core.getStakedAt(staker1.address, bn);
      expect(stakedAt).to.equal(ethers.parseEther('1000'));
    });

    it('should write zero checkpoint on unlock', async function () {
      await core.connect(staker1).stake(ethers.parseEther('1000'), 1, 0);
      await core.connect(staker1).unlock();
      const bn = await ethers.provider.getBlockNumber();
      const stakedAt = await core.getStakedAt(staker1.address, bn);
      expect(stakedAt).to.equal(0);
    });

    it('should return 0 for block before any stake', async function () {
      const bn = await ethers.provider.getBlockNumber();
      const stakedAt = await core.getStakedAt(staker1.address, bn);
      expect(stakedAt).to.equal(0);
    });

    it('should preserve historical checkpoint after unlock', async function () {
      await core.connect(staker1).stake(ethers.parseEther('1000'), 1, 0);
      const stakeBn = await ethers.provider.getBlockNumber();
      await core.connect(staker1).unlock();

      // Historical checkpoint should show the staked amount
      const stakedAt = await core.getStakedAt(staker1.address, stakeBn);
      expect(stakedAt).to.equal(ethers.parseEther('1000'));
    });
  });

  // =========================================================================
  // 4. TWO-STEP ADMIN TRANSFER
  // =========================================================================

  describe('Two-Step Admin Transfer', function () {
    it('should propose admin transfer', async function () {
      const tx = await core.connect(owner).proposeAdminTransfer(admin2.address);
      expect(await core.pendingAdmin()).to.equal(admin2.address);
      await expect(tx).to.emit(core, 'AdminTransferProposed');
    });

    it('should reject proposal with zero address', async function () {
      await expect(
        core.connect(owner).proposeAdminTransfer(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should reject proposal from non-admin', async function () {
      await expect(
        core.connect(staker1).proposeAdminTransfer(admin2.address)
      ).to.be.reverted;
    });

    it('should reject accept before 48h delay', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      await expect(
        core.connect(admin2).acceptAdminTransfer()
      ).to.be.revertedWithCustomError(core, 'AdminTransferNotReady');
    });

    it('should accept admin transfer after 48h delay', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      await time.increase(ADMIN_TRANSFER_DELAY + 1);

      const tx = await core.connect(admin2).acceptAdminTransfer();
      await expect(tx).to.emit(core, 'AdminTransferAccepted');

      // New admin has roles
      expect(await core.hasRole(ADMIN_ROLE, admin2.address)).to.be.true;
      expect(await core.hasRole(DEFAULT_ADMIN_ROLE, admin2.address)).to.be.true;

      // Old admin lost roles
      expect(await core.hasRole(ADMIN_ROLE, owner.address)).to.be.false;
      expect(await core.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.false;
    });

    it('should reject accept from wrong address', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      await time.increase(ADMIN_TRANSFER_DELAY + 1);
      await expect(
        core.connect(staker1).acceptAdminTransfer()
      ).to.be.revertedWithCustomError(core, 'NotPendingAdmin');
    });

    it('should cancel pending admin transfer', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      const tx = await core.connect(owner).cancelAdminTransfer();
      await expect(tx).to.emit(core, 'AdminTransferCancelled');
      expect(await core.pendingAdmin()).to.equal(ethers.ZeroAddress);
      expect(await core.adminTransferEta()).to.equal(0);
    });

    it('should reject cancel from non-admin', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      await expect(
        core.connect(staker1).cancelAdminTransfer()
      ).to.be.reverted;
    });

    it('should allow overwriting pending transfer with new proposal', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      await core.connect(owner).proposeAdminTransfer(validator1.address);
      expect(await core.pendingAdmin()).to.equal(validator1.address);

      // Old pending admin cannot accept
      await time.increase(ADMIN_TRANSFER_DELAY + 1);
      await expect(
        core.connect(admin2).acceptAdminTransfer()
      ).to.be.revertedWithCustomError(core, 'NotPendingAdmin');
    });

    it('should clear pending state after acceptance', async function () {
      await core.connect(owner).proposeAdminTransfer(admin2.address);
      await time.increase(ADMIN_TRANSFER_DELAY + 1);
      await core.connect(admin2).acceptAdminTransfer();

      expect(await core.pendingAdmin()).to.equal(ethers.ZeroAddress);
      expect(await core.adminTransferEta()).to.equal(0);
      expect(await core.adminTransferProposer()).to.equal(ethers.ZeroAddress);
    });
  });

  // =========================================================================
  // 5. LEGACY MIGRATION — Extended
  // =========================================================================

  describe('Legacy Migration — Extended', function () {
    it('should reject registration with mismatched publicKeys length', async function () {
      await expect(
        core.connect(owner).registerLegacyUsers(
          ['user1', 'user2'],
          [ethers.parseEther('100'), ethers.parseEther('200')],
          [ethers.hexlify(ethers.randomBytes(64))] // Only 1 key for 2 users
        )
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });

    it('should reject registration of more than 100 users per batch', async function () {
      const count = 101;
      const usernames = Array.from({ length: count }, (_, i) => `user${i}`);
      const balances = Array(count).fill(ethers.parseEther('100'));
      const keys = Array(count).fill(ethers.hexlify(ethers.randomBytes(64)));

      await expect(
        core.connect(owner).registerLegacyUsers(usernames, balances, keys)
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });

    it('should skip already-registered usernames without reverting', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['user1'], [ethers.parseEther('100')], [key]
      );

      // Register again — should skip (no revert, no double-count)
      await core.connect(owner).registerLegacyUsers(
        ['user1'], [ethers.parseEther('200')], [key]
      );

      const status = await core.getLegacyStatus('user1');
      expect(status.balance).to.equal(ethers.parseEther('100')); // Original amount
    });

    it('should track totalLegacySupply correctly', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['a', 'b'],
        [ethers.parseEther('100'), ethers.parseEther('200')],
        [key, key]
      );
      expect(await core.totalLegacySupply()).to.equal(ethers.parseEther('300'));
    });

    it('should prevent claiming with zero-balance legacy account', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['zeroUser'], [0n], [key]
      );
      await core.connect(owner).setValidator(validator1.address, true);

      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['zeroUser', staker1.address, nonce, core.target, chainId]
        )
      );
      const signature = await validator1.signMessage(ethers.getBytes(messageHash));

      await expect(
        core.connect(staker1).claimLegacyBalance('zeroUser', staker1.address, nonce, [signature])
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });

    it('should prevent claiming unregistered username', async function () {
      await core.connect(owner).setValidator(validator1.address, true);
      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['noSuchUser', staker1.address, nonce, core.target, chainId]
        )
      );
      const signature = await validator1.signMessage(ethers.getBytes(messageHash));

      await expect(
        core.connect(staker1).claimLegacyBalance('noSuchUser', staker1.address, nonce, [signature])
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should prevent claiming to zero address', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['legUser'], [ethers.parseEther('100')], [key]
      );

      await expect(
        core.connect(staker1).claimLegacyBalance('legUser', ethers.ZeroAddress, ethers.randomBytes(32), [])
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should prevent claim with insufficient signatures', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['sigUser'], [ethers.parseEther('100')], [key]
      );
      await core.connect(owner).setRequiredSignatures(2);
      await core.connect(owner).setValidator(validator1.address, true);

      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['sigUser', staker1.address, nonce, core.target, chainId]
        )
      );
      const sig = await validator1.signMessage(ethers.getBytes(messageHash));

      await expect(
        core.connect(staker1).claimLegacyBalance('sigUser', staker1.address, nonce, [sig])
      ).to.be.revertedWithCustomError(core, 'InsufficientSignatures');
    });

    it('should prevent nonce replay across different claims', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['userA', 'userB'],
        [ethers.parseEther('100'), ethers.parseEther('200')],
        [key, key]
      );
      await core.connect(owner).setValidator(validator1.address, true);

      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;

      // Claim userA
      const hash1 = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['userA', staker1.address, nonce, core.target, chainId]
        )
      );
      const sig1 = await validator1.signMessage(ethers.getBytes(hash1));
      await core.connect(staker1).claimLegacyBalance('userA', staker1.address, nonce, [sig1]);

      // Try to claim userB with same nonce — should fail
      const hash2 = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['userB', staker1.address, nonce, core.target, chainId]
        )
      );
      const sig2 = await validator1.signMessage(ethers.getBytes(hash2));
      await expect(
        core.connect(staker1).claimLegacyBalance('userB', staker1.address, nonce, [sig2])
      ).to.be.revertedWithCustomError(core, 'InvalidSignature');
    });

    it('should reject duplicate signer in multi-sig claim', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['dupSigUser'], [ethers.parseEther('100')], [key]
      );
      await core.connect(owner).setRequiredSignatures(2);
      await core.connect(owner).setValidator(validator1.address, true);

      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['dupSigUser', staker1.address, nonce, core.target, chainId]
        )
      );
      const sig = await validator1.signMessage(ethers.getBytes(messageHash));

      // Same signature twice
      await expect(
        core.connect(staker1).claimLegacyBalance('dupSigUser', staker1.address, nonce, [sig, sig])
      ).to.be.revertedWithCustomError(core, 'DuplicateSigner');
    });

    it('should track totalLegacyClaimed after successful claim', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['claimTrack'], [ethers.parseEther('500')], [key]
      );
      await core.connect(owner).setValidator(validator1.address, true);

      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['string', 'address', 'bytes32', 'address', 'uint256'],
          ['claimTrack', staker1.address, nonce, core.target, chainId]
        )
      );
      const sig = await validator1.signMessage(ethers.getBytes(messageHash));

      const before = await core.totalLegacyClaimed();
      await core.connect(staker1).claimLegacyBalance('claimTrack', staker1.address, nonce, [sig]);
      const after = await core.totalLegacyClaimed();
      expect(after - before).to.equal(ethers.parseEther('500'));
    });

    it('should correctly report isUsernameAvailable', async function () {
      expect(await core.isUsernameAvailable('newUser')).to.be.true;
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['newUser'], [ethers.parseEther('100')], [key]
      );
      expect(await core.isUsernameAvailable('newUser')).to.be.false;
    });
  });

  // =========================================================================
  // 6. DEX SETTLEMENT DEPRECATION
  // =========================================================================

  describe('DEX Settlement Deprecation', function () {
    it('should start with dexSettlementDisabled = false', async function () {
      expect(await core.dexSettlementDisabled()).to.be.false;
    });

    it('should disable DEX settlement permanently', async function () {
      const tx = await core.connect(owner).disableDEXSettlement();
      await expect(tx).to.emit(core, 'DEXSettlementPermanentlyDisabled');
      expect(await core.dexSettlementDisabled()).to.be.true;
    });

    it('should reject depositToDEX after disable', async function () {
      await core.connect(owner).disableDEXSettlement();
      await expect(
        core.connect(staker1).depositToDEX(token.target, ethers.parseEther('100'))
      ).to.be.revertedWithCustomError(core, 'DEXSettlementDisabled');
    });

    it('should reject withdrawFromDEX after disable', async function () {
      // Deposit first
      await core.connect(staker1).depositToDEX(token.target, ethers.parseEther('100'));
      await core.connect(owner).disableDEXSettlement();
      await expect(
        core.connect(staker1).withdrawFromDEX(token.target, ethers.parseEther('100'))
      ).to.be.revertedWithCustomError(core, 'DEXSettlementDisabled');
    });

    it('should reject deprecated settleDEXTrade', async function () {
      await core.connect(owner).setValidator(validator1.address, true);
      await expect(
        core.connect(validator1).settleDEXTrade(
          staker1.address, staker2.address, token.target,
          ethers.parseEther('10'), ethers.randomBytes(32)
        )
      ).to.be.revertedWithCustomError(core, 'DeprecatedFunction');
    });

    it('should reject non-admin from disabling DEX', async function () {
      await expect(
        core.connect(staker1).disableDEXSettlement()
      ).to.be.reverted;
    });

    it('should allow calling disableDEXSettlement twice without revert', async function () {
      await core.connect(owner).disableDEXSettlement();
      // Second call should not revert (idempotent)
      await core.connect(owner).disableDEXSettlement();
      expect(await core.dexSettlementDisabled()).to.be.true;
    });
  });

  // =========================================================================
  // 7. UUPS UPGRADE + OSSIFICATION
  // =========================================================================

  describe('UUPS Upgrade & Ossification', function () {
    it('should allow admin to upgrade', async function () {
      const OmniCoreV2 = await ethers.getContractFactory('OmniCore', owner);
      const upgraded = await upgrades.upgradeProxy(
        core.target, OmniCoreV2,
        { constructorArgs: [ethers.ZeroAddress] }
      );
      // Should preserve state
      expect(await upgraded.OMNI_COIN()).to.equal(token.target);
    });

    it('should prevent non-admin from upgrading', async function () {
      const OmniCoreV2 = await ethers.getContractFactory('OmniCore', staker1);
      await expect(
        upgrades.upgradeProxy(core.target, OmniCoreV2, { constructorArgs: [ethers.ZeroAddress] })
      ).to.be.reverted;
    });

    it('should ossify the contract', async function () {
      const tx = await core.connect(owner).ossify();
      await expect(tx).to.emit(core, 'ContractOssified');
      expect(await core.isOssified()).to.be.true;
    });

    it('should prevent upgrade after ossification', async function () {
      await core.connect(owner).ossify();
      const OmniCoreV2 = await ethers.getContractFactory('OmniCore', owner);
      await expect(
        upgrades.upgradeProxy(core.target, OmniCoreV2, { constructorArgs: [ethers.ZeroAddress] })
      ).to.be.revertedWithCustomError(core, 'ContractIsOssified');
    });

    it('should reject ossify from non-admin', async function () {
      await expect(
        core.connect(staker1).ossify()
      ).to.be.reverted;
    });

    it('should allow reinitializeV3 with valid bootstrap', async function () {
      await core.connect(owner).reinitializeV3(validator1.address);
      expect(await core.bootstrapContract()).to.equal(validator1.address);
    });

    it('should reject reinitializeV3 with zero address', async function () {
      await expect(
        core.connect(owner).reinitializeV3(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should reject reinitializeV3 from non-admin', async function () {
      await expect(
        core.connect(staker1).reinitializeV3(validator1.address)
      ).to.be.reverted;
    });
  });

  // =========================================================================
  // 8. PROVISIONER ROLE
  // =========================================================================

  describe('Provisioner Role', function () {
    beforeEach(async function () {
      await core.connect(owner).grantRole(PROVISIONER_ROLE, provisioner.address);
    });

    it('should allow provisioner to provision validator', async function () {
      const tx = await core.connect(provisioner).provisionValidator(validator1.address);
      await expect(tx).to.emit(core, 'ValidatorUpdated');
      expect(await core.validators(validator1.address)).to.be.true;
      expect(await core.hasRole(AVALANCHE_VALIDATOR_ROLE, validator1.address)).to.be.true;
    });

    it('should allow provisioner to deprovision validator', async function () {
      await core.connect(provisioner).provisionValidator(validator1.address);
      await core.connect(provisioner).deprovisionValidator(validator1.address);
      expect(await core.validators(validator1.address)).to.be.false;
      expect(await core.hasRole(AVALANCHE_VALIDATOR_ROLE, validator1.address)).to.be.false;
    });

    it('should reject provision from non-provisioner', async function () {
      await expect(
        core.connect(staker1).provisionValidator(validator1.address)
      ).to.be.reverted;
    });

    it('should reject provision with zero address', async function () {
      await expect(
        core.connect(provisioner).provisionValidator(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should reject deprovision with zero address', async function () {
      await expect(
        core.connect(provisioner).deprovisionValidator(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });
  });

  // =========================================================================
  // 9. FEE ADDRESS MANAGEMENT
  // =========================================================================

  describe('Fee Address Management', function () {
    it('should update ODDAO address', async function () {
      const tx = await core.connect(owner).setOddaoAddress(admin2.address);
      await expect(tx).to.emit(core, 'OddaoAddressUpdated')
        .withArgs(oddao.address, admin2.address);
      expect(await core.oddaoAddress()).to.equal(admin2.address);
    });

    it('should reject zero ODDAO address', async function () {
      await expect(
        core.connect(owner).setOddaoAddress(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should update staking pool address', async function () {
      const tx = await core.connect(owner).setStakingPoolAddress(admin2.address);
      await expect(tx).to.emit(core, 'StakingPoolAddressUpdated')
        .withArgs(stakingPool.address, admin2.address);
      expect(await core.stakingPoolAddress()).to.equal(admin2.address);
    });

    it('should reject zero staking pool address', async function () {
      await expect(
        core.connect(owner).setStakingPoolAddress(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should update protocol treasury address', async function () {
      const tx = await core.connect(owner).setProtocolTreasuryAddress(admin2.address);
      await expect(tx).to.emit(core, 'ProtocolTreasuryAddressUpdated')
        .withArgs(protocolTreasury.address, admin2.address);
      expect(await core.protocolTreasuryAddress()).to.equal(admin2.address);
    });

    it('should reject zero protocol treasury address', async function () {
      await expect(
        core.connect(owner).setProtocolTreasuryAddress(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should reject fee address changes from non-admin', async function () {
      await expect(core.connect(staker1).setOddaoAddress(admin2.address)).to.be.reverted;
      await expect(core.connect(staker1).setStakingPoolAddress(admin2.address)).to.be.reverted;
      await expect(core.connect(staker1).setProtocolTreasuryAddress(admin2.address)).to.be.reverted;
    });
  });

  // =========================================================================
  // 10. DEX DEPOSIT/WITHDRAW
  // =========================================================================

  describe('DEX Deposit & Withdraw', function () {
    it('should deposit tokens to DEX', async function () {
      await core.connect(staker1).depositToDEX(token.target, ethers.parseEther('500'));
      expect(await core.getDEXBalance(staker1.address, token.target)).to.equal(ethers.parseEther('500'));
    });

    it('should reject zero amount deposit', async function () {
      await expect(
        core.connect(staker1).depositToDEX(token.target, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });

    it('should reject zero address token deposit', async function () {
      await expect(
        core.connect(staker1).depositToDEX(ethers.ZeroAddress, ethers.parseEther('100'))
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should withdraw tokens from DEX', async function () {
      await core.connect(staker1).depositToDEX(token.target, ethers.parseEther('500'));
      const before = await token.balanceOf(staker1.address);
      await core.connect(staker1).withdrawFromDEX(token.target, ethers.parseEther('200'));
      const after = await token.balanceOf(staker1.address);
      expect(after - before).to.equal(ethers.parseEther('200'));
      expect(await core.getDEXBalance(staker1.address, token.target)).to.equal(ethers.parseEther('300'));
    });

    it('should reject withdrawal exceeding balance', async function () {
      await core.connect(staker1).depositToDEX(token.target, ethers.parseEther('100'));
      await expect(
        core.connect(staker1).withdrawFromDEX(token.target, ethers.parseEther('101'))
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });

    it('should reject zero amount withdrawal', async function () {
      await expect(
        core.connect(staker1).withdrawFromDEX(token.target, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });
  });

  // =========================================================================
  // 11. REQUIRED SIGNATURES MANAGEMENT
  // =========================================================================

  describe('Required Signatures — Extended', function () {
    it('should set required signatures to MAX (5)', async function () {
      await core.connect(owner).setRequiredSignatures(5);
      expect(await core.requiredSignatures()).to.equal(5);
    });

    it('should emit RequiredSignaturesUpdated event', async function () {
      const tx = await core.connect(owner).setRequiredSignatures(3);
      await expect(tx).to.emit(core, 'RequiredSignaturesUpdated').withArgs(3);
    });

    it('should reject non-admin setting signatures', async function () {
      await expect(
        core.connect(staker1).setRequiredSignatures(2)
      ).to.be.reverted;
    });
  });

  // =========================================================================
  // 12. ADVERSARIAL EDGE CASES
  // =========================================================================

  describe('Adversarial Edge Cases', function () {
    it('should prevent re-staking without unlocking first', async function () {
      await core.connect(staker1).stake(ethers.parseEther('100'), 1, 0);
      await expect(
        core.connect(staker1).stake(ethers.parseEther('200'), 1, 0)
      ).to.be.revertedWithCustomError(core, 'InvalidAmount');
    });

    it('should prevent validator from being set to zero address', async function () {
      await expect(
        core.connect(owner).setValidator(ethers.ZeroAddress, true)
      ).to.be.revertedWithCustomError(core, 'InvalidAddress');
    });

    it('should prevent legacy claim when paused', async function () {
      const key = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers(
        ['pauseUser'], [ethers.parseEther('100')], [key]
      );
      await core.connect(owner).setValidator(validator1.address, true);
      await core.connect(owner).pause();

      await expect(
        core.connect(staker1).claimLegacyBalance(
          'pauseUser', staker1.address, ethers.randomBytes(32), []
        )
      ).to.be.revertedWithCustomError(core, 'EnforcedPause');
    });
  });
});
