const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCore", function () {
  let core;
  let token;
  let owner, validator1, validator2, staker1, staker2;

  const STAKE_AMOUNT = ethers.parseEther("1000");

  beforeEach(async function () {
    [owner, validator1, validator2, staker1, staker2] = await ethers.getSigners();

    // Deploy OmniCoin token
    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy();
    await token.initialize();

    // Deploy upgradeable OmniCore using proxy
    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await upgrades.deployProxy(
      OmniCore,
      [owner.address, token.target, owner.address, owner.address],
      { initializer: "initialize" }
    );

    // Grant MINTER_ROLE to core contract so it can mint rewards
    await token.grantRole(await token.MINTER_ROLE(), core.target);

    // Setup: Give users tokens
    await token.mint(validator1.address, ethers.parseEther("10000"));
    await token.mint(validator2.address, ethers.parseEther("10000"));
    await token.mint(staker1.address, ethers.parseEther("10000"));
    await token.mint(staker2.address, ethers.parseEther("10000"));

    // Mint some tokens to core for rewards distribution
    await token.mint(core.target, ethers.parseEther("100000"));

    // Approve core contract
    await token.connect(validator1).approve(core.target, ethers.parseEther("10000"));
    await token.connect(validator2).approve(core.target, ethers.parseEther("10000"));
    await token.connect(staker1).approve(core.target, ethers.parseEther("10000"));
    await token.connect(staker2).approve(core.target, ethers.parseEther("10000"));
  });

  describe("Initialization", function () {
    it("Should initialize with correct values", async function () {
      expect(await core.OMNI_COIN()).to.equal(token.target);
      expect(await core.oddaoAddress()).to.equal(owner.address);
      expect(await core.stakingPoolAddress()).to.equal(owner.address);
    });

    it("Should not allow re-initialization", async function () {
      await expect(
        core.initialize(owner.address, token.target, owner.address, owner.address)
      ).to.be.reverted;
    });

    it("Should set up roles correctly", async function () {
      const ADMIN_ROLE = await core.ADMIN_ROLE();
      expect(await core.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
    });

    it("Should set requiredSignatures to 1", async function () {
      expect(await core.requiredSignatures()).to.equal(1);
    });
  });

  describe("Upgradeability", function () {
    it("Should prevent non-admin from upgrading", async function () {
      // Try to upgrade as non-admin (validator1) - use OmniCore itself
      const OmniCoreV2 = await ethers.getContractFactory("OmniCore", validator1);

      await expect(
        upgrades.upgradeProxy(core.target, OmniCoreV2)
      ).to.be.reverted;
    });

    it("Should preserve state after theoretical upgrade", async function () {
      // Set up some state
      const serviceId = ethers.id("marketplace");
      const serviceAddress = "0x1234567890123456789012345678901234567890";
      await core.connect(owner).setService(serviceId, serviceAddress);

      // Register a validator
      await core.connect(owner).setValidator(validator1.address, true);

      // Stake some tokens (tier 1 requires >= 1 XOM, duration 30 days is valid)
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60);

      // Verify state before
      const serviceBefore = await core.services(serviceId);
      const isValidatorBefore = await core.validators(validator1.address);
      const stakeBefore = await core.stakes(staker1.address);

      // Verify state remains intact
      expect(await core.services(serviceId)).to.equal(serviceBefore);
      expect(await core.validators(validator1.address)).to.equal(isValidatorBefore);
      const stakeAfter = await core.stakes(staker1.address);
      expect(stakeAfter.amount).to.equal(stakeBefore.amount);
    });
  });

  describe("Service Registry", function () {
    it("Should register services", async function () {
      const serviceId = ethers.id("marketplace");
      const serviceAddress = "0x1234567890123456789012345678901234567890";

      await core.connect(owner).setService(serviceId, serviceAddress);

      expect(await core.services(serviceId)).to.equal(serviceAddress);
    });

    it("Should update service addresses", async function () {
      const serviceId = ethers.id("bridge");
      const oldAddress = "0x1234567890123456789012345678901234567890";
      const newAddress = "0x0987654321098765432109876543210987654321";

      await core.connect(owner).setService(serviceId, oldAddress);
      await core.connect(owner).setService(serviceId, newAddress);

      expect(await core.services(serviceId)).to.equal(newAddress);
    });

    it("Should only allow owner to register services", async function () {
      const serviceId = ethers.id("test");
      const serviceAddress = "0x1234567890123456789012345678901234567890";

      await expect(
        core.connect(validator1).setService(serviceId, serviceAddress)
      ).to.be.reverted;
    });

    it("Should emit ServiceUpdated event", async function () {
      const serviceId = ethers.id("escrow");
      const serviceAddress = "0x1234567890123456789012345678901234567890";

      const tx = await core.connect(owner).setService(serviceId, serviceAddress);
      const block = await ethers.provider.getBlock(tx.blockNumber);

      await expect(tx)
        .to.emit(core, "ServiceUpdated")
        .withArgs(serviceId, serviceAddress, block.timestamp);
    });
  });

  describe("Validator Management", function () {
    it("Should register validators", async function () {
      await core.connect(owner).setValidator(validator1.address, true);

      expect(await core.validators(validator1.address)).to.be.true;
    });

    it("Should remove validators", async function () {
      await core.connect(owner).setValidator(validator1.address, true);
      await core.connect(owner).setValidator(validator1.address, false);

      expect(await core.validators(validator1.address)).to.be.false;
    });

    it("Should emit validator events", async function () {
      const tx1 = await core.connect(owner).setValidator(validator1.address, true);
      const block1 = await ethers.provider.getBlock(tx1.blockNumber);

      await expect(tx1)
        .to.emit(core, "ValidatorUpdated")
        .withArgs(validator1.address, true, block1.timestamp);

      const tx2 = await core.connect(owner).setValidator(validator1.address, false);
      const block2 = await ethers.provider.getBlock(tx2.blockNumber);

      await expect(tx2)
        .to.emit(core, "ValidatorUpdated")
        .withArgs(validator1.address, false, block2.timestamp);
    });

    it("Should grant AVALANCHE_VALIDATOR_ROLE when adding validator", async function () {
      await core.connect(owner).setValidator(validator1.address, true);

      const AVALANCHE_VALIDATOR_ROLE = await core.AVALANCHE_VALIDATOR_ROLE();
      expect(await core.hasRole(AVALANCHE_VALIDATOR_ROLE, validator1.address)).to.be.true;
    });

    it("Should revoke AVALANCHE_VALIDATOR_ROLE when removing validator", async function () {
      await core.connect(owner).setValidator(validator1.address, true);
      await core.connect(owner).setValidator(validator1.address, false);

      const AVALANCHE_VALIDATOR_ROLE = await core.AVALANCHE_VALIDATOR_ROLE();
      expect(await core.hasRole(AVALANCHE_VALIDATOR_ROLE, validator1.address)).to.be.false;
    });
  });

  describe("Pausable (M-04)", function () {
    it("Should allow admin to pause", async function () {
      await core.connect(owner).pause();
      expect(await core.paused()).to.be.true;
    });

    it("Should allow admin to unpause", async function () {
      await core.connect(owner).pause();
      await core.connect(owner).unpause();
      expect(await core.paused()).to.be.false;
    });

    it("Should prevent non-admin from pausing", async function () {
      await expect(
        core.connect(staker1).pause()
      ).to.be.reverted;
    });

    it("Should prevent staking when paused", async function () {
      await core.connect(owner).pause();

      await expect(
        core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "EnforcedPause");
    });

    it("Should prevent unlock when paused", async function () {
      // Stake first while not paused
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 0); // No lock duration

      // Pause
      await core.connect(owner).pause();

      await expect(
        core.connect(staker1).unlock()
      ).to.be.revertedWithCustomError(core, "EnforcedPause");
    });

    it("Should prevent DEX deposit when paused", async function () {
      await core.connect(owner).pause();

      await expect(
        core.connect(staker1).depositToDEX(token.target, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(core, "EnforcedPause");
    });

    it("Should prevent DEX withdrawal when paused", async function () {
      // Deposit first while not paused
      await core.connect(staker1).depositToDEX(token.target, ethers.parseEther("100"));

      await core.connect(owner).pause();

      await expect(
        core.connect(staker1).withdrawFromDEX(token.target, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(core, "EnforcedPause");
    });
  });

  describe("Minimal Staking", function () {
    it("Should allow staking", async function () {
      const tier = 1;
      const duration = 30 * 24 * 60 * 60; // 30 days

      await core.connect(staker1).stake(STAKE_AMOUNT, tier, duration);

      const position = await core.stakes(staker1.address);
      expect(position.amount).to.equal(STAKE_AMOUNT);
      expect(position.tier).to.equal(tier);
      expect(position.duration).to.equal(duration);
      expect(position.active).to.be.true;
    });

    it("Should transfer tokens on stake", async function () {
      const balanceBefore = await token.balanceOf(staker1.address);
      const coreBalanceBefore = await token.balanceOf(core.target);

      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60);

      const balanceAfter = await token.balanceOf(staker1.address);
      const coreBalanceAfter = await token.balanceOf(core.target);

      expect(balanceBefore - balanceAfter).to.equal(STAKE_AMOUNT);
      expect(coreBalanceAfter - coreBalanceBefore).to.equal(STAKE_AMOUNT);
    });

    it("Should enforce non-zero stake amount", async function () {
      await expect(
        core.connect(staker1).stake(0, 1, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });

    it("Should prevent staking with existing position", async function () {
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60);

      await expect(
        core.connect(staker1).stake(STAKE_AMOUNT, 1, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });

    it("Should reject invalid staking tier (tier 0)", async function () {
      await expect(
        core.connect(staker1).stake(STAKE_AMOUNT, 0, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidStakingTier");
    });

    it("Should reject invalid staking tier (tier 6)", async function () {
      await expect(
        core.connect(staker1).stake(STAKE_AMOUNT, 6, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidStakingTier");
    });

    it("Should reject tier/amount mismatch (tier 2 with insufficient amount)", async function () {
      // Tier 2 requires >= 1,000,000 XOM
      await expect(
        core.connect(staker1).stake(ethers.parseEther("999"), 2, 30 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidStakingTier");
    });

    it("Should reject invalid duration", async function () {
      // 60 days is not a valid duration (valid: 0, 30d, 180d, 730d)
      await expect(
        core.connect(staker1).stake(STAKE_AMOUNT, 1, 60 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(core, "InvalidDuration");
    });

    it("Should allow staking with no lock duration (0)", async function () {
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 0);

      const position = await core.stakes(staker1.address);
      expect(position.amount).to.equal(STAKE_AMOUNT);
      expect(position.duration).to.equal(0);
      expect(position.active).to.be.true;
    });
  });

  describe("Unlock Staking", function () {
    it("Should allow unlock after lock period expires", async function () {
      const duration = 30 * 24 * 60 * 60; // 30 days
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, duration);

      // Fast forward past the lock period
      await time.increase(duration + 1);

      const balanceBefore = await token.balanceOf(staker1.address);
      await core.connect(staker1).unlock();
      const balanceAfter = await token.balanceOf(staker1.address);

      expect(balanceAfter - balanceBefore).to.equal(STAKE_AMOUNT);

      // Check stake position cleared
      const position = await core.stakes(staker1.address);
      expect(position.amount).to.equal(0);
      expect(position.active).to.be.false;
    });

    it("Should prevent unlock before lock period", async function () {
      const duration = 30 * 24 * 60 * 60; // 30 days
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, duration);

      await expect(
        core.connect(staker1).unlock()
      ).to.be.revertedWithCustomError(core, "StakeLocked");
    });

    it("Should allow immediate unlock with zero duration", async function () {
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 0);

      const balanceBefore = await token.balanceOf(staker1.address);
      await core.connect(staker1).unlock();
      const balanceAfter = await token.balanceOf(staker1.address);

      expect(balanceAfter - balanceBefore).to.equal(STAKE_AMOUNT);
    });

    it("Should revert unlock with no active stake", async function () {
      await expect(
        core.connect(staker1).unlock()
      ).to.be.revertedWithCustomError(core, "StakeNotFound");
    });

    it("Should update totalStaked on unlock", async function () {
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 0);

      const totalStakedBefore = await core.totalStaked();
      await core.connect(staker1).unlock();
      const totalStakedAfter = await core.totalStaked();

      expect(totalStakedBefore - totalStakedAfter).to.equal(STAKE_AMOUNT);
    });

    it("Should emit TokensUnlocked event", async function () {
      await core.connect(staker1).stake(STAKE_AMOUNT, 1, 0);

      const tx = await core.connect(staker1).unlock();
      const block = await ethers.provider.getBlock(tx.blockNumber);

      await expect(tx)
        .to.emit(core, "TokensUnlocked")
        .withArgs(staker1.address, STAKE_AMOUNT, block.timestamp);
    });
  });

  describe("Legacy Migration with Public Keys", function () {
    it("Should register legacy users with public keys", async function () {
      const usernames = ["user1", "user2", "user3"];
      const balances = [
        ethers.parseEther("1000"),
        ethers.parseEther("2000"),
        ethers.parseEther("3000")
      ];
      const publicKeys = [
        ethers.hexlify(ethers.randomBytes(64)),
        ethers.hexlify(ethers.randomBytes(64)),
        ethers.hexlify(ethers.randomBytes(64))
      ];

      await core.connect(owner).registerLegacyUsers(usernames, balances, publicKeys);

      // Verify registration
      for (let i = 0; i < usernames.length; i++) {
        const status = await core.getLegacyStatus(usernames[i]);
        expect(status.reserved).to.be.true;
        expect(status.balance).to.equal(balances[i]);
        expect(status.claimed).to.be.false;
        expect(status.publicKey).to.equal(publicKeys[i]);
      }
    });

    it("Should return public key in legacy status", async function () {
      const username = "legacyUser";
      const balance = ethers.parseEther("5000");
      const publicKey = ethers.hexlify(ethers.randomBytes(64));

      await core.connect(owner).registerLegacyUsers([username], [balance], [publicKey]);

      const status = await core.getLegacyStatus(username);
      expect(status.publicKey).to.equal(publicKey);
    });

    it("Should require matching array lengths", async function () {
      const usernames = ["user1", "user2"];
      const balances = [ethers.parseEther("1000")]; // Mismatched length
      const publicKeys = [ethers.hexlify(ethers.randomBytes(64)), ethers.hexlify(ethers.randomBytes(64))];

      await expect(
        core.connect(owner).registerLegacyUsers(usernames, balances, publicKeys)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });

    it("Should emit LegacyUsersRegistered event", async function () {
      const usernames = ["user1"];
      const balances = [ethers.parseEther("1000")];
      const publicKeys = [ethers.hexlify(ethers.randomBytes(64))];

      const tx = await core.connect(owner).registerLegacyUsers(usernames, balances, publicKeys);

      await expect(tx)
        .to.emit(core, "LegacyUsersRegistered")
        .withArgs(1, ethers.parseEther("1000"));
    });
  });

  describe("Legacy Claim with Multi-Sig Signatures", function () {
    const username = "legacyUser";
    const balance = ethers.parseEther("5000");

    beforeEach(async function () {
      const publicKey = ethers.hexlify(ethers.randomBytes(64));
      await core.connect(owner).registerLegacyUsers([username], [balance], [publicKey]);

      // Register validator1 as a validator
      await core.connect(owner).setValidator(validator1.address, true);
    });

    it("Should claim legacy balance with valid signature", async function () {
      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;

      // Compute message hash using abi.encode (M-02 fix)
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["string", "address", "bytes32", "address", "uint256"],
          [username, staker1.address, nonce, core.target, chainId]
        )
      );

      const ethSignedMessageHash = ethers.solidityPackedKeccak256(
        ["string", "bytes32"],
        ["\x19Ethereum Signed Message:\n32", messageHash]
      );

      // Sign with validator1
      const signature = await validator1.signMessage(ethers.getBytes(messageHash));

      const balanceBefore = await token.balanceOf(staker1.address);
      await core.connect(staker1).claimLegacyBalance(
        username, staker1.address, nonce, [signature]
      );
      const balanceAfter = await token.balanceOf(staker1.address);

      expect(balanceAfter - balanceBefore).to.equal(balance);
    });

    it("Should prevent double claim", async function () {
      const nonce = ethers.randomBytes(32);
      const chainId = (await ethers.provider.getNetwork()).chainId;

      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["string", "address", "bytes32", "address", "uint256"],
          [username, staker1.address, nonce, core.target, chainId]
        )
      );

      const signature = await validator1.signMessage(ethers.getBytes(messageHash));

      await core.connect(staker1).claimLegacyBalance(
        username, staker1.address, nonce, [signature]
      );

      // Try to claim again
      await expect(
        core.connect(staker1).claimLegacyBalance(
          username, staker1.address, nonce, [signature]
        )
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });
  });

  describe("initializeV2 (M-05)", function () {
    it("Should restrict initializeV2 to ADMIN_ROLE", async function () {
      await expect(
        core.connect(staker1).initializeV2()
      ).to.be.reverted;
    });
  });

  describe("Required Signatures Management", function () {
    it("Should allow admin to set required signatures", async function () {
      await core.connect(owner).setRequiredSignatures(3);
      expect(await core.requiredSignatures()).to.equal(3);
    });

    it("Should reject zero required signatures", async function () {
      await expect(
        core.connect(owner).setRequiredSignatures(0)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });

    it("Should reject required signatures above MAX_REQUIRED_SIGNATURES", async function () {
      await expect(
        core.connect(owner).setRequiredSignatures(6)
      ).to.be.revertedWithCustomError(core, "InvalidAmount");
    });
  });

  describe("Integration", function () {
    it("Should work with multiple stakers", async function () {
      // Both stakers use tier 1 (>= 1 XOM) with valid durations
      await core.connect(staker1).stake(ethers.parseEther("1000"), 1, 30 * 24 * 60 * 60);
      await core.connect(staker2).stake(ethers.parseEther("2000"), 1, 180 * 24 * 60 * 60);

      // Check positions
      const position1 = await core.stakes(staker1.address);
      const position2 = await core.stakes(staker2.address);

      expect(position1.amount).to.equal(ethers.parseEther("1000"));
      expect(position1.tier).to.equal(1);

      expect(position2.amount).to.equal(ethers.parseEther("2000"));
      expect(position2.tier).to.equal(1);
    });

    it("Should handle service lookups", async function () {
      // Register all services
      await core.connect(owner).setService(ethers.id("token"), token.target);
      await core.connect(owner).setService(ethers.id("marketplace"), "0x1234567890123456789012345678901234567890");
      await core.connect(owner).setService(ethers.id("bridge"), "0x2345678901234567890123456789012345678901");

      // Verify lookups
      expect(await core.services(ethers.id("token"))).to.equal(token.target);
      expect(await core.services(ethers.id("nonexistent"))).to.equal(ethers.ZeroAddress);
    });

    it("Should track totalStaked correctly with multiple stakers", async function () {
      await core.connect(staker1).stake(ethers.parseEther("1000"), 1, 0);
      await core.connect(staker2).stake(ethers.parseEther("2000"), 1, 0);

      expect(await core.totalStaked()).to.equal(ethers.parseEther("3000"));

      // Unlock staker1
      await core.connect(staker1).unlock();

      expect(await core.totalStaked()).to.equal(ethers.parseEther("2000"));
    });
  });
});
