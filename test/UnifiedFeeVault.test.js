const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title UnifiedFeeVault Test Suite
 * @notice Comprehensive tests for the unified fee collection and
 *         70/20/10 distribution vault (ODDAO / Staking / Protocol).
 * @dev Tests cover:
 *   1. Initialization (roles, recipients, zero-address guards)
 *   2. Deposit (access control, token transfer, events, guards)
 *   3. Distribute (70/20/10 split, permissionless, math, events)
 *   4. Bridge-to-treasury (BRIDGE_ROLE, balance tracking, events)
 *   5. View functions (undistributed, pendingForBridge, isOssified)
 *   6. Admin functions (setRecipients, pause, unpause, ossify)
 *   7. Pausable behaviour (blocked during pause)
 *   8. Reentrancy safety (via nonReentrant modifier)
 *   9. Multi-token support (XOM + USDC independently)
 *  10. UUPS upgradeability (authorized upgrade, ossification block)
 */
describe("UnifiedFeeVault", function () {
  let vault, xom, usdc;
  let admin, stakingPool, protocolTreasury;
  let depositor, bridger, user, attacker;

  const DEPOSIT_AMOUNT = ethers.parseEther("10000");
  const BPS_DENOMINATOR = 10000n;
  const ODDAO_BPS = 7000n;
  const STAKING_BPS = 2000n;
  const PROTOCOL_BPS = 1000n;

  /**
   * Deploy fresh instances of MockERC20 (XOM, USDC) and
   * UnifiedFeeVault proxy before each test.
   */
  beforeEach(async function () {
    const signers = await ethers.getSigners();
    admin = signers[0];
    stakingPool = signers[1];
    protocolTreasury = signers[2];
    depositor = signers[3];
    bridger = signers[4];
    user = signers[5];
    attacker = signers[6];

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.waitForDeployment();
    usdc = await MockERC20.deploy("USD Coin", "USDC");
    await usdc.waitForDeployment();

    // Deploy UnifiedFeeVault via UUPS proxy
    const Vault = await ethers.getContractFactory("UnifiedFeeVault");
    vault = await upgrades.deployProxy(
      Vault,
      [admin.address, stakingPool.address, protocolTreasury.address],
      { initializer: "initialize", kind: "uups" }
    );
    await vault.waitForDeployment();

    // Grant DEPOSITOR_ROLE to depositor
    const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
    await vault.connect(admin).grantRole(DEPOSITOR_ROLE, depositor.address);

    // Grant BRIDGE_ROLE to bridger
    const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
    await vault.connect(admin).grantRole(BRIDGE_ROLE, bridger.address);

    // Mint tokens to depositor and approve vault
    await xom.mint(depositor.address, ethers.parseEther("1000000"));
    await usdc.mint(depositor.address, ethers.parseEther("1000000"));
    await xom
      .connect(depositor)
      .approve(vault.target, ethers.parseEther("1000000"));
    await usdc
      .connect(depositor)
      .approve(vault.target, ethers.parseEther("1000000"));
  });

  // ─────────────────────────────────────────────────────────────────────
  //  1. Initialization
  // ─────────────────────────────────────────────────────────────────────

  describe("Initialization", function () {
    it("should set correct recipients", async function () {
      expect(await vault.stakingPool()).to.equal(stakingPool.address);
      expect(await vault.protocolTreasury()).to.equal(
        protocolTreasury.address
      );
    });

    it("should grant DEFAULT_ADMIN_ROLE to admin", async function () {
      const DEFAULT_ADMIN_ROLE = await vault.DEFAULT_ADMIN_ROLE();
      expect(await vault.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be
        .true;
    });

    it("should grant ADMIN_ROLE to admin", async function () {
      const ADMIN_ROLE = await vault.ADMIN_ROLE();
      expect(await vault.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("should grant BRIDGE_ROLE to admin", async function () {
      const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
      expect(await vault.hasRole(BRIDGE_ROLE, admin.address)).to.be.true;
    });

    it("should start unossified", async function () {
      expect(await vault.isOssified()).to.be.false;
    });

    it("should revert on zero admin address", async function () {
      const Vault = await ethers.getContractFactory("UnifiedFeeVault");
      await expect(
        upgrades.deployProxy(
          Vault,
          [
            ethers.ZeroAddress,
            stakingPool.address,
            protocolTreasury.address,
          ],
          { initializer: "initialize", kind: "uups" }
        )
      ).to.be.revertedWithCustomError(Vault, "ZeroAddress");
    });

    it("should revert on zero staking pool address", async function () {
      const Vault = await ethers.getContractFactory("UnifiedFeeVault");
      await expect(
        upgrades.deployProxy(
          Vault,
          [admin.address, ethers.ZeroAddress, protocolTreasury.address],
          { initializer: "initialize", kind: "uups" }
        )
      ).to.be.revertedWithCustomError(Vault, "ZeroAddress");
    });

    it("should revert on zero protocol treasury address", async function () {
      const Vault = await ethers.getContractFactory("UnifiedFeeVault");
      await expect(
        upgrades.deployProxy(
          Vault,
          [admin.address, stakingPool.address, ethers.ZeroAddress],
          { initializer: "initialize", kind: "uups" }
        )
      ).to.be.revertedWithCustomError(Vault, "ZeroAddress");
    });

    it("should not allow double initialization", async function () {
      await expect(
        vault
          .connect(admin)
          .initialize(
            admin.address,
            stakingPool.address,
            protocolTreasury.address
          )
      ).to.be.revertedWithCustomError(vault, "InvalidInitialization");
    });

    it("should set correct BPS constants", async function () {
      expect(await vault.ODDAO_BPS()).to.equal(ODDAO_BPS);
      expect(await vault.STAKING_BPS()).to.equal(STAKING_BPS);
      expect(await vault.PROTOCOL_BPS()).to.equal(PROTOCOL_BPS);
      expect(await vault.BPS_DENOMINATOR()).to.equal(BPS_DENOMINATOR);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  2. Deposit
  // ─────────────────────────────────────────────────────────────────────

  describe("Deposit", function () {
    it("should accept deposits from DEPOSITOR_ROLE", async function () {
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);

      expect(await xom.balanceOf(vault.target)).to.equal(DEPOSIT_AMOUNT);
    });

    it("should emit FeesDeposited event", async function () {
      await expect(
        vault.connect(depositor).deposit(xom.target, DEPOSIT_AMOUNT)
      )
        .to.emit(vault, "FeesDeposited")
        .withArgs(xom.target, DEPOSIT_AMOUNT, depositor.address);
    });

    it("should revert for non-DEPOSITOR_ROLE", async function () {
      const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
      await xom.mint(attacker.address, DEPOSIT_AMOUNT);
      await xom.connect(attacker).approve(vault.target, DEPOSIT_AMOUNT);

      await expect(
        vault.connect(attacker).deposit(xom.target, DEPOSIT_AMOUNT)
      )
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, DEPOSITOR_ROLE);
    });

    it("should revert on zero token address", async function () {
      await expect(
        vault
          .connect(depositor)
          .deposit(ethers.ZeroAddress, DEPOSIT_AMOUNT)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should revert on zero amount", async function () {
      await expect(
        vault.connect(depositor).deposit(xom.target, 0)
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");
    });

    it("should handle multiple deposits", async function () {
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);

      expect(await xom.balanceOf(vault.target)).to.equal(
        DEPOSIT_AMOUNT * 2n
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  3. Distribute
  // ─────────────────────────────────────────────────────────────────────

  describe("Distribute", function () {
    beforeEach(async function () {
      // Deposit fees so there's something to distribute
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
    });

    it("should split fees 70/20/10", async function () {
      const expectedODDAO =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
      const expectedStaking =
        (DEPOSIT_AMOUNT * STAKING_BPS) / BPS_DENOMINATOR;
      const expectedProtocol =
        DEPOSIT_AMOUNT - expectedODDAO - expectedStaking;

      await vault.connect(user).distribute(xom.target);

      // ODDAO share stays in vault as pendingBridge
      expect(await vault.pendingBridge(xom.target)).to.equal(
        expectedODDAO
      );
      // Staking pool receives 20%
      expect(await xom.balanceOf(stakingPool.address)).to.equal(
        expectedStaking
      );
      // Protocol treasury receives 10%
      expect(await xom.balanceOf(protocolTreasury.address)).to.equal(
        expectedProtocol
      );
    });

    it("should be permissionless (anyone can call)", async function () {
      await expect(vault.connect(user).distribute(xom.target)).to.not.be
        .reverted;
    });

    it("should emit FeesDistributed event", async function () {
      const expectedODDAO =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
      const expectedStaking =
        (DEPOSIT_AMOUNT * STAKING_BPS) / BPS_DENOMINATOR;
      const expectedProtocol =
        DEPOSIT_AMOUNT - expectedODDAO - expectedStaking;

      await expect(vault.connect(user).distribute(xom.target))
        .to.emit(vault, "FeesDistributed")
        .withArgs(xom.target, expectedODDAO, expectedStaking, expectedProtocol);
    });

    it("should update totalDistributed", async function () {
      await vault.connect(user).distribute(xom.target);
      expect(await vault.totalDistributed(xom.target)).to.equal(
        DEPOSIT_AMOUNT
      );
    });

    it("should revert with NothingToDistribute when balance is zero",
      async function () {
        // Distribute the existing deposit
        await vault.connect(user).distribute(xom.target);

        // Now nothing left to distribute
        await expect(
          vault.connect(user).distribute(xom.target)
        ).to.be.revertedWithCustomError(vault, "NothingToDistribute");
      }
    );

    it("should revert on zero token address", async function () {
      await expect(
        vault.connect(user).distribute(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should correctly exclude pendingBridge from distributable",
      async function () {
        // First distribution
        await vault.connect(user).distribute(xom.target);

        const pending = await vault.pendingBridge(xom.target);
        const vaultBalance = await xom.balanceOf(vault.target);

        // Vault only has the 70% ODDAO share left
        expect(vaultBalance).to.equal(pending);

        // Second distribution should fail (nothing to distribute)
        await expect(
          vault.connect(user).distribute(xom.target)
        ).to.be.revertedWithCustomError(vault, "NothingToDistribute");
      }
    );

    it("should handle sequential deposits and distributions",
      async function () {
        // First distribute
        await vault.connect(user).distribute(xom.target);
        const pending1 = await vault.pendingBridge(xom.target);

        // Second deposit
        await vault
          .connect(depositor)
          .deposit(xom.target, DEPOSIT_AMOUNT);

        // Second distribute
        await vault.connect(user).distribute(xom.target);
        const pending2 = await vault.pendingBridge(xom.target);

        // Pending bridge should have accumulated both ODDAO shares
        const expectedODDAO =
          (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
        expect(pending2).to.equal(expectedODDAO * 2n);

        // totalDistributed should be cumulative
        expect(await vault.totalDistributed(xom.target)).to.equal(
          DEPOSIT_AMOUNT * 2n
        );
      }
    );

    it("should handle dust correctly (protocol gets remainder)",
      async function () {
        // Deposit an amount that doesn't divide evenly
        const oddAmount = ethers.parseEther("33.333333333333333333");
        await vault
          .connect(depositor)
          .deposit(xom.target, oddAmount);

        await vault.connect(user).distribute(xom.target);

        const oddaoShare =
          (oddAmount * ODDAO_BPS) / BPS_DENOMINATOR;
        const stakingShare =
          (oddAmount * STAKING_BPS) / BPS_DENOMINATOR;
        const protocolShare = oddAmount - oddaoShare - stakingShare;

        // The three amounts must sum exactly to the deposited amount
        // (minus the ODDAO share that stays in vault from the first
        // deposit which was also distributed)
        const totalInVault =
          DEPOSIT_AMOUNT + oddAmount;
        const totalODDAO =
          (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR + oddaoShare;

        expect(await vault.pendingBridge(xom.target)).to.equal(
          totalODDAO
        );

        // Staking pool received both distributions' staking shares
        const totalStaking =
          (DEPOSIT_AMOUNT * STAKING_BPS) / BPS_DENOMINATOR +
          stakingShare;
        expect(await xom.balanceOf(stakingPool.address)).to.equal(
          totalStaking
        );
      }
    );
  });

  // ─────────────────────────────────────────────────────────────────────
  //  4. Bridge to Treasury
  // ─────────────────────────────────────────────────────────────────────

  describe("BridgeToTreasury", function () {
    let oddaoShare;

    beforeEach(async function () {
      // Deposit and distribute to build up pendingBridge
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(xom.target);

      oddaoShare =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
    });

    it("should transfer ODDAO share to bridge receiver", async function () {
      const receiver = user.address;
      const balanceBefore = await xom.balanceOf(receiver);

      await vault
        .connect(bridger)
        .bridgeToTreasury(xom.target, oddaoShare, receiver);

      expect(await xom.balanceOf(receiver)).to.equal(
        balanceBefore + oddaoShare
      );
    });

    it("should reduce pendingBridge", async function () {
      await vault
        .connect(bridger)
        .bridgeToTreasury(xom.target, oddaoShare, user.address);

      expect(await vault.pendingBridge(xom.target)).to.equal(0n);
    });

    it("should update totalBridged", async function () {
      await vault
        .connect(bridger)
        .bridgeToTreasury(xom.target, oddaoShare, user.address);

      expect(await vault.totalBridged(xom.target)).to.equal(oddaoShare);
    });

    it("should emit FeesBridged event", async function () {
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, user.address)
      )
        .to.emit(vault, "FeesBridged")
        .withArgs(xom.target, oddaoShare, user.address);
    });

    it("should allow partial bridge", async function () {
      const half = oddaoShare / 2n;

      await vault
        .connect(bridger)
        .bridgeToTreasury(xom.target, half, user.address);

      expect(await vault.pendingBridge(xom.target)).to.equal(
        oddaoShare - half
      );
    });

    it("should revert for non-BRIDGE_ROLE", async function () {
      const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
      await expect(
        vault
          .connect(attacker)
          .bridgeToTreasury(xom.target, oddaoShare, user.address)
      )
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, BRIDGE_ROLE);
    });

    it("should revert when amount exceeds pending", async function () {
      const excessive = oddaoShare + 1n;
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, excessive, user.address)
      )
        .to.be.revertedWithCustomError(
          vault,
          "InsufficientPendingBalance"
        )
        .withArgs(excessive, oddaoShare);
    });

    it("should revert on zero token address", async function () {
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(
            ethers.ZeroAddress,
            oddaoShare,
            user.address
          )
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should revert on zero receiver address", async function () {
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should revert on zero amount", async function () {
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, 0, user.address)
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  5. View Functions
  // ─────────────────────────────────────────────────────────────────────

  describe("View Functions", function () {
    it("should return full balance as undistributed before distribute",
      async function () {
        await vault
          .connect(depositor)
          .deposit(xom.target, DEPOSIT_AMOUNT);

        expect(await vault.undistributed(xom.target)).to.equal(
          DEPOSIT_AMOUNT
        );
      }
    );

    it("should return zero undistributed after distribute",
      async function () {
        await vault
          .connect(depositor)
          .deposit(xom.target, DEPOSIT_AMOUNT);
        await vault.connect(user).distribute(xom.target);

        expect(await vault.undistributed(xom.target)).to.equal(0n);
      }
    );

    it("should return zero for undeposited token", async function () {
      expect(await vault.undistributed(xom.target)).to.equal(0n);
      expect(await vault.pendingForBridge(xom.target)).to.equal(0n);
    });

    it("should track pendingForBridge correctly", async function () {
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(xom.target);

      const expected =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
      expect(await vault.pendingForBridge(xom.target)).to.equal(expected);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  6. Admin Functions
  // ─────────────────────────────────────────────────────────────────────

  describe("Admin Functions", function () {
    it("should update recipients via proposeRecipients + applyRecipients", async function () {
      const newStaking = user.address;
      const newTreasury = attacker.address;

      // Propose new recipients (starts 48h timelock)
      await vault
        .connect(admin)
        .proposeRecipients(newStaking, newTreasury);

      // Advance time past the 48h timelock
      await time.increase(48 * 60 * 60 + 1);

      // Apply the change
      await vault.connect(admin).applyRecipients();

      expect(await vault.stakingPool()).to.equal(newStaking);
      expect(await vault.protocolTreasury()).to.equal(newTreasury);
    });

    it("should emit RecipientsUpdated event on applyRecipients", async function () {
      await vault
        .connect(admin)
        .proposeRecipients(user.address, attacker.address);

      await time.increase(48 * 60 * 60 + 1);

      await expect(
        vault.connect(admin).applyRecipients()
      )
        .to.emit(vault, "RecipientsUpdated")
        .withArgs(user.address, attacker.address);
    });

    it("should revert proposeRecipients for non-ADMIN_ROLE",
      async function () {
        const ADMIN_ROLE = await vault.ADMIN_ROLE();
        await expect(
          vault
            .connect(attacker)
            .proposeRecipients(user.address, attacker.address)
        )
          .to.be.revertedWithCustomError(
            vault,
            "AccessControlUnauthorizedAccount"
          )
          .withArgs(attacker.address, ADMIN_ROLE);
      }
    );

    it("should revert proposeRecipients with zero staking pool",
      async function () {
        await expect(
          vault
            .connect(admin)
            .proposeRecipients(ethers.ZeroAddress, protocolTreasury.address)
        ).to.be.revertedWithCustomError(vault, "ZeroAddress");
      }
    );

    it("should revert proposeRecipients with zero protocol treasury",
      async function () {
        await expect(
          vault
            .connect(admin)
            .proposeRecipients(stakingPool.address, ethers.ZeroAddress)
        ).to.be.revertedWithCustomError(vault, "ZeroAddress");
      }
    );

    it("should distribute to new recipients after proposeRecipients + applyRecipients",
      async function () {
        // Propose and apply new recipients
        const newStaking = user;
        const newTreasury = attacker;
        await vault
          .connect(admin)
          .proposeRecipients(newStaking.address, newTreasury.address);

        await time.increase(48 * 60 * 60 + 1);
        await vault.connect(admin).applyRecipients();

        // Deposit and distribute
        await vault
          .connect(depositor)
          .deposit(xom.target, DEPOSIT_AMOUNT);
        await vault.connect(user).distribute(xom.target);

        const expectedStaking =
          (DEPOSIT_AMOUNT * STAKING_BPS) / BPS_DENOMINATOR;
        const expectedODDAO =
          (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
        const expectedProtocol =
          DEPOSIT_AMOUNT - expectedODDAO - expectedStaking;

        expect(await xom.balanceOf(newStaking.address)).to.equal(
          expectedStaking
        );
        expect(await xom.balanceOf(newTreasury.address)).to.equal(
          expectedProtocol
        );
      }
    );
  });

  // ─────────────────────────────────────────────────────────────────────
  //  7. Pausable
  // ─────────────────────────────────────────────────────────────────────

  describe("Pausable", function () {
    it("should pause and unpause", async function () {
      await vault.connect(admin).pause();
      expect(await vault.paused()).to.be.true;

      await vault.connect(admin).unpause();
      expect(await vault.paused()).to.be.false;
    });

    it("should block deposit when paused", async function () {
      await vault.connect(admin).pause();

      await expect(
        vault.connect(depositor).deposit(xom.target, DEPOSIT_AMOUNT)
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });

    it("should block distribute when paused", async function () {
      // Deposit first while unpaused
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);

      await vault.connect(admin).pause();

      await expect(
        vault.connect(user).distribute(xom.target)
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });

    it("should block bridgeToTreasury when paused", async function () {
      // Setup: deposit, distribute, then pause
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(xom.target);
      const oddaoShare =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;

      await vault.connect(admin).pause();

      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, user.address)
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });

    it("should revert pause for non-ADMIN_ROLE", async function () {
      const ADMIN_ROLE = await vault.ADMIN_ROLE();
      await expect(vault.connect(attacker).pause())
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, ADMIN_ROLE);
    });

    it("should revert unpause for non-ADMIN_ROLE", async function () {
      await vault.connect(admin).pause();
      const ADMIN_ROLE = await vault.ADMIN_ROLE();
      await expect(vault.connect(attacker).unpause())
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, ADMIN_ROLE);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  8. Ossification
  // ─────────────────────────────────────────────────────────────────────

  describe("Ossification", function () {
    it("should ossify the contract", async function () {
      await vault.connect(admin).ossify();
      expect(await vault.isOssified()).to.be.true;
    });

    it("should emit ContractOssified event", async function () {
      await expect(vault.connect(admin).ossify())
        .to.emit(vault, "ContractOssified")
        .withArgs(admin.address);
    });

    it("should revert ossify for non-DEFAULT_ADMIN_ROLE",
      async function () {
        const DEFAULT_ADMIN_ROLE = await vault.DEFAULT_ADMIN_ROLE();
        await expect(vault.connect(attacker).ossify())
          .to.be.revertedWithCustomError(
            vault,
            "AccessControlUnauthorizedAccount"
          )
          .withArgs(attacker.address, DEFAULT_ADMIN_ROLE);
      }
    );

    it("should block UUPS upgrade when ossified", async function () {
      await vault.connect(admin).ossify();

      const VaultV2 = await ethers.getContractFactory("UnifiedFeeVault");
      await expect(
        upgrades.upgradeProxy(vault.target, VaultV2)
      ).to.be.revertedWithCustomError(vault, "ContractIsOssified");
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  9. Multi-token Support
  // ─────────────────────────────────────────────────────────────────────

  describe("Multi-token Support", function () {
    it("should track XOM and USDC independently", async function () {
      const xomAmount = ethers.parseEther("5000");
      const usdcAmount = ethers.parseEther("2000");

      // Deposit both tokens
      await vault.connect(depositor).deposit(xom.target, xomAmount);
      await vault.connect(depositor).deposit(usdc.target, usdcAmount);

      // Distribute XOM only
      await vault.connect(user).distribute(xom.target);

      // XOM should be distributed
      const xomODDAO = (xomAmount * ODDAO_BPS) / BPS_DENOMINATOR;
      expect(await vault.pendingBridge(xom.target)).to.equal(xomODDAO);
      expect(await vault.totalDistributed(xom.target)).to.equal(
        xomAmount
      );

      // USDC should still be undistributed
      expect(await vault.undistributed(usdc.target)).to.equal(usdcAmount);
      expect(await vault.pendingBridge(usdc.target)).to.equal(0n);

      // Now distribute USDC
      await vault.connect(user).distribute(usdc.target);

      const usdcODDAO = (usdcAmount * ODDAO_BPS) / BPS_DENOMINATOR;
      expect(await vault.pendingBridge(usdc.target)).to.equal(usdcODDAO);
    });

    it("should bridge different tokens independently", async function () {
      // Deposit and distribute both
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault
        .connect(depositor)
        .deposit(usdc.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(xom.target);
      await vault.connect(user).distribute(usdc.target);

      const oddaoShare =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;

      // Bridge only XOM
      await vault
        .connect(bridger)
        .bridgeToTreasury(xom.target, oddaoShare, user.address);

      // XOM bridged, USDC still pending
      expect(await vault.pendingBridge(xom.target)).to.equal(0n);
      expect(await vault.totalBridged(xom.target)).to.equal(oddaoShare);
      expect(await vault.pendingBridge(usdc.target)).to.equal(oddaoShare);
      expect(await vault.totalBridged(usdc.target)).to.equal(0n);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  10. UUPS Upgradeability
  // ─────────────────────────────────────────────────────────────────────

  describe("UUPS Upgradeability", function () {
    it("should allow upgrade by DEFAULT_ADMIN_ROLE", async function () {
      const VaultV2 = await ethers.getContractFactory("UnifiedFeeVault");
      const upgraded = await upgrades.upgradeProxy(
        vault.target,
        VaultV2
      );
      expect(upgraded.target).to.equal(vault.target);
    });

    it("should revert upgrade by non-admin", async function () {
      const VaultV2 = await ethers.getContractFactory(
        "UnifiedFeeVault",
        attacker
      );
      await expect(
        upgrades.upgradeProxy(vault.target, VaultV2)
      ).to.be.revertedWithCustomError(
        vault,
        "AccessControlUnauthorizedAccount"
      );
    });

    it("should preserve state after upgrade", async function () {
      // Deposit and distribute
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(xom.target);

      const pendingBefore = await vault.pendingBridge(xom.target);
      const totalDistBefore = await vault.totalDistributed(xom.target);

      // Upgrade
      const VaultV2 = await ethers.getContractFactory("UnifiedFeeVault");
      const upgraded = await upgrades.upgradeProxy(
        vault.target,
        VaultV2
      );

      // State should be preserved
      expect(await upgraded.pendingBridge(xom.target)).to.equal(
        pendingBefore
      );
      expect(await upgraded.totalDistributed(xom.target)).to.equal(
        totalDistBefore
      );
      expect(await upgraded.stakingPool()).to.equal(
        stakingPool.address
      );
      expect(await upgraded.protocolTreasury()).to.equal(
        protocolTreasury.address
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  11. Mathematical Correctness
  // ─────────────────────────────────────────────────────────────────────

  describe("Mathematical Correctness", function () {
    it("should ensure 70+20+10 always equals 100% of input",
      async function () {
        // Test with several different amounts
        const amounts = [
          ethers.parseEther("1"),
          ethers.parseEther("100"),
          ethers.parseEther("999.999999999999999999"),
          ethers.parseEther("1000000"),
          1n, // 1 wei
          3n, // causes rounding
          7n, // causes rounding
          ethers.parseEther("123456.789012345678901234"),
        ];

        for (const amount of amounts) {
          const oddao = (amount * ODDAO_BPS) / BPS_DENOMINATOR;
          const staking = (amount * STAKING_BPS) / BPS_DENOMINATOR;
          const protocol = amount - oddao - staking;

          // Sum must equal input
          expect(oddao + staking + protocol).to.equal(amount);

          // Protocol (remainder) must be >= floor(amount * 1000 / 10000)
          const protocolFloor =
            (amount * PROTOCOL_BPS) / BPS_DENOMINATOR;
          expect(protocol).to.be.gte(protocolFloor);
        }
      }
    );

    it("should handle 1 wei deposit correctly", async function () {
      await xom.mint(depositor.address, 1n);
      await xom.connect(depositor).approve(vault.target, 1n);
      await vault.connect(depositor).deposit(xom.target, 1n);

      await vault.connect(user).distribute(xom.target);

      // 1 * 7000 / 10000 = 0, 1 * 2000 / 10000 = 0
      // protocol = 1 - 0 - 0 = 1 (all dust goes to protocol)
      expect(await vault.pendingBridge(xom.target)).to.equal(0n);
      expect(await xom.balanceOf(stakingPool.address)).to.equal(0n);
      expect(await xom.balanceOf(protocolTreasury.address)).to.equal(1n);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  12. Direct Token Transfer (edge case)
  // ─────────────────────────────────────────────────────────────────────

  describe("Direct Token Transfer", function () {
    it("should distribute tokens sent directly (not via deposit)",
      async function () {
        // Send tokens directly to vault (bypassing deposit())
        await xom.mint(admin.address, DEPOSIT_AMOUNT);
        await xom
          .connect(admin)
          .transfer(vault.target, DEPOSIT_AMOUNT);

        // distribute() uses balanceOf, so it picks up direct transfers
        await vault.connect(user).distribute(xom.target);

        const expectedODDAO =
          (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
        expect(await vault.pendingBridge(xom.target)).to.equal(
          expectedODDAO
        );
      }
    );
  });
});
