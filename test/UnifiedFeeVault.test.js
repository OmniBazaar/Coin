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
 *   6. Admin functions (proposeRecipients/applyRecipients, pause, unpause, ossify)
 *   7. Pausable behaviour (blocked during pause)
 *   8. Reentrancy safety (via nonReentrant modifier)
 *   9. Multi-token support (XOM + USDC independently)
 *  10. UUPS upgradeability (authorized upgrade, ossification block)
 */
/**
 * Get a UnifiedFeeVault contract factory with freshly deployed
 * external libraries linked. The vault delegatecalls the 9-way
 * marketplace split into `MarketplaceFeeSplitter`, the EIP-2981
 * creator-royalty payout into `RoyaltyResolver`, and the
 * OmniSwapRouter hop into `SwapExecutor` (all extracted to keep the
 * vault under the 24 KiB EIP-170 limit).
 *
 * @returns {Promise<import("ethers").ContractFactory>} linked factory
 */
async function deployLib(name, opts) {
  const factory = await ethers.getContractFactory(name, opts);
  const lib = await factory.deploy();
  await lib.waitForDeployment();
  return lib.getAddress();
}
async function getLinkedVaultFactory() {
  // Vault links MarketplaceFeeSplitter + CoinAgnosticSettlement +
  // PrioritySettlement; the leaf libraries (RoyaltyResolver,
  // SwapExecutor, BuyIntentValidator) link INTO the two settlement
  // libraries (sale-time priority-surcharge refactor, EIP-170 budget).
  const marketplaceFeeSplitter = await deployLib("MarketplaceFeeSplitter");
  const royaltyResolver = await deployLib("RoyaltyResolver");
  const swapExecutor = await deployLib("SwapExecutor");
  const buyIntentValidator = await deployLib("BuyIntentValidator");
  const coinAgnosticSettlement = await deployLib("CoinAgnosticSettlement", {
    libraries: {
      MarketplaceFeeSplitter: marketplaceFeeSplitter,
      RoyaltyResolver: royaltyResolver,
      SwapExecutor: swapExecutor
    }
  });
  const prioritySettlement = await deployLib("PrioritySettlement", {
    libraries: {
      CoinAgnosticSettlement: coinAgnosticSettlement,
      BuyIntentValidator: buyIntentValidator
    }
  });
  const nftSellerConsent = await deployLib("NftSellerConsent");
  const bridgeDestinationLib = await deployLib("BridgeDestinationLib");
  return ethers.getContractFactory("UnifiedFeeVault", {
    libraries: {
      MarketplaceFeeSplitter: marketplaceFeeSplitter,
      CoinAgnosticSettlement: coinAgnosticSettlement,
      PrioritySettlement: prioritySettlement,
      NftSellerConsent: nftSellerConsent,
      BridgeDestinationLib: bridgeDestinationLib
    }
  });
}

describe("UnifiedFeeVault", function () {
  let vault, xom, usdc;
  let admin, stakingPool, protocolTreasury;
  let depositor, bridger, user, attacker;

  const DEPOSIT_AMOUNT = ethers.parseEther("10000");
  const BPS_DENOMINATOR = 10000n;
  const ODDAO_BPS = 7000n;
  const STAKING_BPS = 2000n;
  const PROTOCOL_BPS = 1000n;
  const TIMELOCK_DELAY = 48 * 60 * 60; // 48 hours in seconds

  /**
   * Helper: propose recipients, advance time past the 48-hour
   * timelock, then apply the change. Used wherever the old
   * setRecipients() was called.
   */
  async function timelockSetRecipients(vaultRef, signer, sp, pt) {
    await vaultRef.connect(signer).proposeRecipients(sp, pt);
    await time.increase(TIMELOCK_DELAY + 1);
    await vaultRef.connect(signer).applyRecipients();
  }

  /**
   * Helper: propose token bridge mode, advance time past the
   * 48-hour timelock, then apply the change. Used wherever
   * the old setTokenBridgeMode() was called.
   */
  async function timelockSetTokenBridgeMode(vaultRef, signer, token, mode) {
    await vaultRef.connect(signer).proposeTokenBridgeMode(token, mode);
    await time.increase(TIMELOCK_DELAY + 1);
    await vaultRef.connect(signer).applyTokenBridgeMode();
  }

  /**
   * Helper: propose XOM token, advance time past the 48-hour
   * timelock, then apply the change. Used wherever the old
   * setXomToken() was called.
   */
  async function timelockSetXomToken(vaultRef, signer, xomAddr) {
    await vaultRef.connect(signer).proposeXomToken(xomAddr);
    await time.increase(TIMELOCK_DELAY + 1);
    await vaultRef.connect(signer).applyXomToken();
  }

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

    // Deploy UnifiedFeeVault via UUPS proxy (with the external
    // MarketplaceFeeSplitter library deployed + linked).
    const Vault = await getLinkedVaultFactory();
    vault = await upgrades.deployProxy(
      Vault,
      [admin.address, stakingPool.address, protocolTreasury.address],
      {
        initializer: "initialize",
        kind: "uups",
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ["constructor", "external-library-linking"]
      }
    );
    await vault.waitForDeployment();

    // Grant DEPOSITOR_ROLE to depositor
    const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
    await vault.connect(admin).grantRole(DEPOSITOR_ROLE, depositor.address);

    // Grant BRIDGE_ROLE to bridger
    const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
    await vault.connect(admin).grantRole(BRIDGE_ROLE, bridger.address);

    // VT-21: pin the bridge destination to `user` so the existing bridge
    // tests (which pass `user.address` as the receiver) exercise the
    // pinned-destination path. Fresh deploys seed the canonical ODDAO
    // treasury, not a test signer, so the pin must be re-pointed here.
    await vault.connect(admin).setBridgeDestination(user.address);

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
      const Vault = await getLinkedVaultFactory();
      await expect(
        upgrades.deployProxy(
          Vault,
          [
            ethers.ZeroAddress,
            stakingPool.address,
            protocolTreasury.address,
          ],
          {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
        )
      ).to.be.revertedWithCustomError(Vault, "ZeroAddress");
    });

    it("should revert on zero staking pool address", async function () {
      const Vault = await getLinkedVaultFactory();
      await expect(
        upgrades.deployProxy(
          Vault,
          [admin.address, ethers.ZeroAddress, protocolTreasury.address],
          {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
        )
      ).to.be.revertedWithCustomError(Vault, "ZeroAddress");
    });

    it("should revert on zero protocol treasury address", async function () {
      const Vault = await getLinkedVaultFactory();
      await expect(
        upgrades.deployProxy(
          Vault,
          [admin.address, stakingPool.address, ethers.ZeroAddress],
          {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
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
      // VT-21: the caller-supplied receiver must equal the pinned
      // destination. Zero never matches a non-zero pin → WrongDestination
      // (the old ZeroAddress revert on the receiver is subsumed).
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "WrongDestination");
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
  //  4b. VT-21 Bridge destination pin
  // ─────────────────────────────────────────────────────────────────────

  describe("VT-21 bridge destination pin", function () {
    let oddaoShare;

    beforeEach(async function () {
      await vault
        .connect(depositor)
        .deposit(xom.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(xom.target);
      oddaoShare = (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
    });

    it("exposes the pinned destination and an unlocked latch", async function () {
      expect(await vault.bridgeDestination()).to.equal(user.address);
      expect(await vault.bridgeDestinationLocked()).to.equal(false);
    });

    it("allows DEFAULT_ADMIN_ROLE to move the destination and emits", async function () {
      const newDest = attacker.address;
      await expect(
        vault.connect(admin).setBridgeDestination(newDest)
      )
        .to.emit(vault, "BridgeDestinationUpdated")
        .withArgs(user.address, newDest);
      expect(await vault.bridgeDestination()).to.equal(newDest);

      // Bridging to the old destination now reverts; the new one works.
      await expect(
        vault.connect(bridger).bridgeToTreasury(
          xom.target, oddaoShare, user.address
        )
      ).to.be.revertedWithCustomError(vault, "WrongDestination");
      await vault.connect(bridger).bridgeToTreasury(
        xom.target, oddaoShare, newDest
      );
    });

    it("reverts setBridgeDestination for non-admin", async function () {
      await expect(
        vault.connect(attacker).setBridgeDestination(attacker.address)
      ).to.be.revertedWithCustomError(
        vault,
        "AccessControlUnauthorizedAccount"
      );
    });

    it("reverts setBridgeDestination for the zero address", async function () {
      await expect(
        vault.connect(admin).setBridgeDestination(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("reverts WrongDestination for a mismatched receiver", async function () {
      await expect(
        vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, attacker.address)
      ).to.be.revertedWithCustomError(vault, "WrongDestination");
    });

    it("locks the destination one-way", async function () {
      await vault.connect(admin).lockBridgeDestination();
      expect(await vault.bridgeDestinationLocked()).to.equal(true);

      // Once latched, the setter reverts for everyone, including admin.
      await expect(
        vault.connect(admin).setBridgeDestination(attacker.address)
      ).to.be.revertedWithCustomError(vault, "BridgeDestinationLocked");
      await expect(
        vault.connect(admin).lockBridgeDestination()
      ).to.be.revertedWithCustomError(vault, "BridgeDestinationLocked");
    });

    it("reverts BridgeDestinationNotSet when the destination is zero", async function () {
      // Deploy a fresh vault, but skip re-pointing the destination; the
      // seeded canonical ODDAO treasury is non-zero, so this path is only
      // reachable on a misconfigured upgrade. Force it by bridging with a
      // receiver that cannot match and observing the guard order: a zero
      // destination would raise BridgeDestinationNotSet before WrongDestination.
      const Vault = await getLinkedVaultFactory();
      const freshVault = await upgrades.deployProxy(
        Vault,
        [admin.address, stakingPool.address, protocolTreasury.address],
        {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
      );
      await freshVault.waitForDeployment();

      // The fresh vault seeds the canonical ODDAO treasury, NOT zero, so
      // a mismatched receiver is WrongDestination (guard is live), and the
      // seeded value is what a future governance handover latches.
      expect(await freshVault.bridgeDestination()).to.equal(
        "0x664B6347a69A22b35348D42E4640CA92e1609378"
      );
      const BRIDGE_ROLE = await freshVault.BRIDGE_ROLE();
      await freshVault.connect(admin).grantRole(BRIDGE_ROLE, bridger.address);
      await expect(
        freshVault
          .connect(bridger)
          .bridgeToTreasury(xom.target, 1, bridger.address)
      ).to.be.revertedWithCustomError(freshVault, "WrongDestination");
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
    it("should update recipients via proposeRecipients + applyRecipients",
      async function () {
        const newStaking = user.address;
        const newTreasury = attacker.address;

        await timelockSetRecipients(vault, admin, newStaking, newTreasury);

        expect(await vault.stakingPool()).to.equal(newStaking);
        expect(await vault.protocolTreasury()).to.equal(newTreasury);
      }
    );

    it("should emit RecipientsProposed on propose and RecipientsUpdated on apply",
      async function () {
        await expect(
          vault.connect(admin).proposeRecipients(user.address, attacker.address)
        )
          .to.emit(vault, "RecipientsProposed");

        await time.increase(TIMELOCK_DELAY + 1);

        await expect(
          vault.connect(admin).applyRecipients()
        )
          .to.emit(vault, "RecipientsUpdated")
          .withArgs(user.address, attacker.address);
      }
    );

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
        const newStaking = user;
        const newTreasury = attacker;
        await timelockSetRecipients(
          vault, admin, newStaking.address, newTreasury.address
        );

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
    it("should ossify the contract via propose/confirm",
      async function () {
        await vault.connect(admin).proposeOssification();
        await time.increase(48 * 3600); // 48 hours
        await vault.connect(admin).confirmOssification();
        expect(await vault.isOssified()).to.be.true;
      }
    );

    it("should emit ContractOssified event", async function () {
      await vault.connect(admin).proposeOssification();
      await time.increase(48 * 3600);
      await expect(vault.connect(admin).confirmOssification())
        .to.emit(vault, "ContractOssified")
        .withArgs(admin.address);
    });

    it("should revert ossify for non-DEFAULT_ADMIN_ROLE",
      async function () {
        const DEFAULT_ADMIN_ROLE = await vault.DEFAULT_ADMIN_ROLE();
        await expect(
          vault.connect(attacker).proposeOssification()
        )
          .to.be.revertedWithCustomError(
            vault,
            "AccessControlUnauthorizedAccount"
          )
          .withArgs(attacker.address, DEFAULT_ADMIN_ROLE);
      }
    );

    it("should revert confirmOssification before timelock",
      async function () {
        await vault.connect(admin).proposeOssification();
        await expect(
          vault.connect(admin).confirmOssification()
        ).to.be.revertedWithCustomError(
          vault, "TimelockNotExpired"
        );
      }
    );

    it("should revert confirmOssification with no proposal",
      async function () {
        await expect(
          vault.connect(admin).confirmOssification()
        ).to.be.revertedWithCustomError(
          vault, "NoPendingChange"
        );
      }
    );

    it("should block UUPS upgrade when ossified", async function () {
      await vault.connect(admin).proposeOssification();
      await time.increase(48 * 3600);
      await vault.connect(admin).confirmOssification();

      const VaultV2 = await getLinkedVaultFactory();
      await expect(
        upgrades.upgradeProxy(vault.target, VaultV2, {
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        })
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
      const VaultV2 = await getLinkedVaultFactory();
      const upgraded = await upgrades.upgradeProxy(
        vault.target,
        VaultV2,
        {
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
      );
      expect(upgraded.target).to.equal(vault.target);
    });

    it("should revert upgrade by non-admin", async function () {
      const marketplaceFeeSplitter =
        await deployLib("MarketplaceFeeSplitter");
      const royaltyResolver = await deployLib("RoyaltyResolver");
      const swapExecutor = await deployLib("SwapExecutor");
      const buyIntentValidator = await deployLib("BuyIntentValidator");
      const coinAgnosticSettlement = await deployLib(
        "CoinAgnosticSettlement",
        {
          libraries: {
            MarketplaceFeeSplitter: marketplaceFeeSplitter,
            RoyaltyResolver: royaltyResolver,
            SwapExecutor: swapExecutor
          }
        }
      );
      const prioritySettlement = await deployLib("PrioritySettlement", {
        libraries: {
          CoinAgnosticSettlement: coinAgnosticSettlement,
          BuyIntentValidator: buyIntentValidator
        }
      });
      const nftSellerConsent = await deployLib("NftSellerConsent");
      const bridgeDestinationLib = await deployLib("BridgeDestinationLib");
      const VaultV2 = await ethers.getContractFactory(
        "UnifiedFeeVault",
        {
          signer: attacker,
          libraries: {
            MarketplaceFeeSplitter: marketplaceFeeSplitter,
            CoinAgnosticSettlement: coinAgnosticSettlement,
            PrioritySettlement: prioritySettlement,
            NftSellerConsent: nftSellerConsent,
            BridgeDestinationLib: bridgeDestinationLib
          }
        }
      );
      await expect(
        upgrades.upgradeProxy(vault.target, VaultV2, {
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        })
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
      const VaultV2 = await getLinkedVaultFactory();
      const upgraded = await upgrades.upgradeProxy(
        vault.target,
        VaultV2,
        {
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
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

    it("should skip dust amounts below 10 wei (L-03 fix)",
      async function () {
        // L-03 audit fix: distribute() skips amounts < 10 to avoid
        // broken 70/20/10 splits from integer rounding.
        await xom.mint(depositor.address, 1n);
        await xom.connect(depositor).approve(vault.target, 1n);
        await vault.connect(depositor).deposit(xom.target, 1n);

        // distribute() should silently return for dust (< 10 wei)
        await vault.connect(user).distribute(xom.target);

        // Nothing distributed: funds remain in vault
        expect(await vault.pendingBridge(xom.target)).to.equal(0n);
        expect(await xom.balanceOf(stakingPool.address)).to.equal(0n);
        expect(
          await xom.balanceOf(protocolTreasury.address)
        ).to.equal(0n);
        // 1 wei still sits in the vault
        expect(await xom.balanceOf(vault.target)).to.equal(1n);
      }
    );
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

  // ─────────────────────────────────────────────────────────────────────
  //  13. Token Bridge Mode Configuration
  // ─────────────────────────────────────────────────────────────────────

  describe("Token Bridge Mode", function () {
    it("should default to IN_KIND (0) for any token", async function () {
      expect(await vault.tokenBridgeMode(xom.target)).to.equal(0);
      expect(await vault.tokenBridgeMode(usdc.target)).to.equal(0);
    });

    it("should allow ADMIN_ROLE to set SWAP_TO_XOM mode via timelock",
      async function () {
        await timelockSetTokenBridgeMode(
          vault, admin, usdc.target, 1
        ); // SWAP_TO_XOM
        expect(await vault.tokenBridgeMode(usdc.target)).to.equal(1);
      }
    );

    it("should allow ADMIN_ROLE to set back to IN_KIND via timelock",
      async function () {
        await timelockSetTokenBridgeMode(vault, admin, usdc.target, 1);
        await timelockSetTokenBridgeMode(vault, admin, usdc.target, 0);
        expect(await vault.tokenBridgeMode(usdc.target)).to.equal(0);
      }
    );

    it("should emit BridgeModeProposed on propose and TokenBridgeModeSet on apply",
      async function () {
        await expect(
          vault.connect(admin).proposeTokenBridgeMode(usdc.target, 1)
        )
          .to.emit(vault, "BridgeModeProposed");

        await time.increase(TIMELOCK_DELAY + 1);

        await expect(
          vault.connect(admin).applyTokenBridgeMode()
        )
          .to.emit(vault, "TokenBridgeModeSet")
          .withArgs(usdc.target, 1);
      }
    );

    it("should revert proposeTokenBridgeMode for non-ADMIN_ROLE",
      async function () {
        const ADMIN_ROLE = await vault.ADMIN_ROLE();
        await expect(
          vault.connect(attacker).proposeTokenBridgeMode(usdc.target, 1)
        )
          .to.be.revertedWithCustomError(
            vault,
            "AccessControlUnauthorizedAccount"
          )
          .withArgs(attacker.address, ADMIN_ROLE);
      }
    );
  });

  // ─────────────────────────────────────────────────────────────────────
  //  14. Swap Router Configuration
  // ─────────────────────────────────────────────────────────────────────

  describe("Swap Router Config (timelocked)", function () {
    it("should propose and apply swap router after timelock",
      async function () {
        await vault.connect(admin).proposeSwapRouter(user.address);
        await time.increase(48 * 3600); // 48 hours
        await vault.connect(admin).applySwapRouter();
        expect(await vault.swapRouter()).to.equal(user.address);
      }
    );

    it("should emit SwapRouterProposed and SwapRouterUpdated",
      async function () {
        await expect(
          vault.connect(admin).proposeSwapRouter(user.address)
        ).to.emit(vault, "SwapRouterProposed");

        await time.increase(48 * 3600);
        await expect(
          vault.connect(admin).applySwapRouter()
        ).to.emit(vault, "SwapRouterUpdated");
      }
    );

    it("applies immediately after propose (Pioneer delay=0); reverts NoPendingChange with nothing pending", async function () {
      // RECIPIENT_CHANGE_DELAY is 0 during Pioneer, so apply succeeds in the
      // same block as propose. The remaining guard is the pending-change check.
      await expect(
        vault.connect(admin).applySwapRouter()
      ).to.be.revertedWithCustomError(vault, "NoPendingChange");
      await vault.connect(admin).proposeSwapRouter(user.address);
      await expect(
        vault.connect(admin).applySwapRouter()
      ).to.emit(vault, "SwapRouterUpdated");
    });

    it("should revert for non-ADMIN_ROLE", async function () {
      const ADMIN_ROLE = await vault.ADMIN_ROLE();
      await expect(
        vault.connect(attacker).proposeSwapRouter(user.address)
      )
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, ADMIN_ROLE);
    });

    it("should revert on zero address", async function () {
      await expect(
        vault.connect(admin).proposeSwapRouter(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should revert apply with no pending change", async function () {
      await expect(
        vault.connect(admin).applySwapRouter()
      ).to.be.revertedWithCustomError(vault, "NoPendingChange");
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  15. XOM Token Configuration
  // ─────────────────────────────────────────────────────────────────────

  describe("XOM Token Config (timelocked)", function () {
    it("should allow ADMIN_ROLE to set XOM token via timelock",
      async function () {
        await timelockSetXomToken(vault, admin, xom.target);
        expect(await vault.xomToken()).to.equal(xom.target);
      }
    );

    it("should emit XOMTokenProposed on propose and XOMTokenUpdated on apply",
      async function () {
        await expect(
          vault.connect(admin).proposeXomToken(xom.target)
        ).to.emit(vault, "XOMTokenProposed");

        await time.increase(TIMELOCK_DELAY + 1);

        await expect(
          vault.connect(admin).applyXomToken()
        )
          .to.emit(vault, "XOMTokenUpdated")
          .withArgs(xom.target);
      }
    );

    it("should revert proposeXomToken on zero address", async function () {
      await expect(
        vault.connect(admin).proposeXomToken(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  16. Privacy Bridge Configuration
  // ─────────────────────────────────────────────────────────────────────

  describe("Privacy Bridge Config (timelocked)", function () {
    it("should propose and apply privacy bridge after timelock",
      async function () {
        await vault
          .connect(admin)
          .proposePrivacyBridge(user.address, attacker.address);
        await time.increase(48 * 3600);
        await vault.connect(admin).applyPrivacyBridge();
        expect(await vault.privacyBridge()).to.equal(user.address);
        expect(await vault.pxomToken()).to.equal(attacker.address);
      }
    );

    it("should emit PrivacyBridgeProposed and PrivacyBridgeUpdated",
      async function () {
        await expect(
          vault
            .connect(admin)
            .proposePrivacyBridge(user.address, attacker.address)
        ).to.emit(vault, "PrivacyBridgeProposed");

        await time.increase(48 * 3600);
        await expect(
          vault.connect(admin).applyPrivacyBridge()
        ).to.emit(vault, "PrivacyBridgeUpdated");
      }
    );

    it("applies immediately after propose (Pioneer delay=0); reverts NoPendingChange with nothing pending", async function () {
      // RECIPIENT_CHANGE_DELAY is 0 during Pioneer, so apply succeeds in the
      // same block as propose. The remaining guard is the pending-change check.
      await expect(
        vault.connect(admin).applyPrivacyBridge()
      ).to.be.revertedWithCustomError(vault, "NoPendingChange");
      await vault
        .connect(admin)
        .proposePrivacyBridge(user.address, attacker.address);
      await expect(
        vault.connect(admin).applyPrivacyBridge()
      ).to.not.be.reverted;
    });

    it("should revert for non-ADMIN_ROLE", async function () {
      const ADMIN_ROLE = await vault.ADMIN_ROLE();
      await expect(
        vault
          .connect(attacker)
          .proposePrivacyBridge(user.address, attacker.address)
      )
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, ADMIN_ROLE);
    });

    it("should revert on zero bridge address", async function () {
      await expect(
        vault
          .connect(admin)
          .proposePrivacyBridge(
            ethers.ZeroAddress, attacker.address
          )
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should revert on zero pxom address", async function () {
      await expect(
        vault
          .connect(admin)
          .proposePrivacyBridge(
            user.address, ethers.ZeroAddress
          )
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("should revert apply with no pending change", async function () {
      await expect(
        vault.connect(admin).applyPrivacyBridge()
      ).to.be.revertedWithCustomError(vault, "NoPendingChange");
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  17. swapAndBridge
  // ─────────────────────────────────────────────────────────────────────

  describe("swapAndBridge", function () {
    let mockSwapRouter, oddaoShare, deadline;

    beforeEach(async function () {
      // Deploy mock swap router (1:1 exchange rate = 1e18)
      const MockFeeSwapRouter = await ethers.getContractFactory(
        "MockFeeSwapRouter"
      );
      mockSwapRouter = await MockFeeSwapRouter.deploy(
        ethers.parseEther("1"),  // 1:1 rate
        xom.target               // output = XOM
      );
      await mockSwapRouter.waitForDeployment();

      // Configure vault: propose+apply swap router, set XOM token
      await vault
        .connect(admin)
        .proposeSwapRouter(mockSwapRouter.target);
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applySwapRouter();
      await timelockSetXomToken(vault, admin, xom.target);

      // Deposit USDC fees and distribute to build pendingBridge
      await vault
        .connect(depositor)
        .deposit(usdc.target, DEPOSIT_AMOUNT);
      await vault.connect(user).distribute(usdc.target);
      oddaoShare =
        (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;

      // M-03 audit fix: deadline = 1 hour from now
      deadline = (await time.latest()) + 3600;
    });

    it("should swap USDC to XOM and transfer to receiver",
      async function () {
        const receiverBefore = await xom.balanceOf(user.address);

        await vault.connect(bridger).swapAndBridge(
          usdc.target, oddaoShare, 0, user.address, deadline
        );

        const receiverAfter = await xom.balanceOf(user.address);
        expect(receiverAfter - receiverBefore).to.equal(oddaoShare);
      }
    );

    it("should deduct pendingBridge[token]", async function () {
      await vault.connect(bridger).swapAndBridge(
        usdc.target, oddaoShare, 0, user.address, deadline
      );

      expect(await vault.pendingBridge(usdc.target)).to.equal(0n);
    });

    it("should update totalBridged[token]", async function () {
      await vault.connect(bridger).swapAndBridge(
        usdc.target, oddaoShare, 0, user.address, deadline
      );

      expect(await vault.totalBridged(usdc.target)).to.equal(
        oddaoShare
      );
    });

    it("should emit FeesSwappedAndBridged event", async function () {
      await expect(
        vault.connect(bridger).swapAndBridge(
          usdc.target, oddaoShare, 0, user.address, deadline
        )
      )
        .to.emit(vault, "FeesSwappedAndBridged")
        .withArgs(usdc.target, oddaoShare, oddaoShare, user.address);
    });

    it("should revert for non-BRIDGE_ROLE", async function () {
      const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
      await expect(
        vault.connect(attacker).swapAndBridge(
          usdc.target, oddaoShare, 0, user.address, deadline
        )
      )
        .to.be.revertedWithCustomError(
          vault,
          "AccessControlUnauthorizedAccount"
        )
        .withArgs(attacker.address, BRIDGE_ROLE);
    });

    it("should revert when deadline has passed", async function () {
      const pastDeadline = (await time.latest()) - 1;
      await expect(
        vault.connect(bridger).swapAndBridge(
          usdc.target, oddaoShare, 0, user.address, pastDeadline
        )
      ).to.be.revertedWithCustomError(vault, "DeadlineExpired");
    });

    it("should revert when swap router not set", async function () {
      const Vault = await getLinkedVaultFactory();
      const freshVault = await upgrades.deployProxy(
        Vault,
        [admin.address, stakingPool.address, protocolTreasury.address],
        {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
      );
      await freshVault.waitForDeployment();

      const BR = await freshVault.BRIDGE_ROLE();
      await freshVault.connect(admin).grantRole(BR, bridger.address);
      await timelockSetXomToken(freshVault, admin, xom.target);

      const dl = (await time.latest()) + 3600;
      await expect(
        freshVault.connect(bridger).swapAndBridge(
          usdc.target, 1, 0, user.address, dl
        )
      ).to.be.revertedWithCustomError(freshVault, "SwapRouterNotSet");
    });

    it("should revert when XOM token not set", async function () {
      const Vault = await getLinkedVaultFactory();
      const freshVault = await upgrades.deployProxy(
        Vault,
        [admin.address, stakingPool.address, protocolTreasury.address],
        {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
      );
      await freshVault.waitForDeployment();

      const BR = await freshVault.BRIDGE_ROLE();
      await freshVault.connect(admin).grantRole(BR, bridger.address);
      // Need to propose+apply swap router through timelock
      await freshVault
        .connect(admin)
        .proposeSwapRouter(mockSwapRouter.target);
      await time.increase(48 * 3600);
      await freshVault.connect(admin).applySwapRouter();

      const dl = (await time.latest()) + 3600;
      await expect(
        freshVault.connect(bridger).swapAndBridge(
          usdc.target, 1, 0, user.address, dl
        )
      ).to.be.revertedWithCustomError(freshVault, "XOMTokenNotSet");
    });

    it("should revert when amount exceeds pending", async function () {
      const excessive = oddaoShare + 1n;
      await expect(
        vault.connect(bridger).swapAndBridge(
          usdc.target, excessive, 0, user.address, deadline
        )
      )
        .to.be.revertedWithCustomError(
          vault,
          "InsufficientPendingBalance"
        )
        .withArgs(excessive, oddaoShare);
    });

    it("should enforce slippage protection", async function () {
      const impossibleMin = oddaoShare * 10n;
      await expect(
        vault.connect(bridger).swapAndBridge(
          usdc.target, oddaoShare, impossibleMin,
          user.address, deadline
        )
      ).to.be.revertedWithCustomError(
        vault,
        "InsufficientSwapOutput"
      );
    });

    it("should revert when paused", async function () {
      await vault.connect(admin).pause();
      await expect(
        vault.connect(bridger).swapAndBridge(
          usdc.target, oddaoShare, 0, user.address, deadline
        )
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  19. In-Kind Bridging Still Works
  // ─────────────────────────────────────────────────────────────────────

  describe("In-Kind Bridging Unchanged", function () {
    it("should still bridge USDC in-kind via bridgeToTreasury",
      async function () {
        await vault
          .connect(depositor)
          .deposit(usdc.target, DEPOSIT_AMOUNT);
        await vault.connect(user).distribute(usdc.target);

        const oddaoShare =
          (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;
        const receiverBefore = await usdc.balanceOf(user.address);

        await vault
          .connect(bridger)
          .bridgeToTreasury(usdc.target, oddaoShare, user.address);

        expect(await usdc.balanceOf(user.address)).to.equal(
          receiverBefore + oddaoShare
        );
        expect(await vault.pendingBridge(usdc.target)).to.equal(0n);
        expect(await vault.totalBridged(usdc.target)).to.equal(
          oddaoShare
        );
      }
    );

    it("should still bridge XOM in-kind via bridgeToTreasury",
      async function () {
        await vault
          .connect(depositor)
          .deposit(xom.target, DEPOSIT_AMOUNT);
        await vault.connect(user).distribute(xom.target);

        const oddaoShare =
          (DEPOSIT_AMOUNT * ODDAO_BPS) / BPS_DENOMINATOR;

        await vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, user.address);

        expect(await vault.pendingBridge(xom.target)).to.equal(0n);
        expect(await vault.totalBridged(xom.target)).to.equal(
          oddaoShare
        );
      }
    );

    it("should handle mixed: in-kind for one token, swap for another",
      async function () {
        // Setup swap router for USDC->XOM via timelock
        const MockFeeSwapRouter = await ethers.getContractFactory(
          "MockFeeSwapRouter"
        );
        const mockRouter = await MockFeeSwapRouter.deploy(
          ethers.parseEther("1"),
          xom.target
        );
        await mockRouter.waitForDeployment();
        await vault
          .connect(admin)
          .proposeSwapRouter(mockRouter.target);
        await time.increase(TIMELOCK_DELAY + 1);
        await vault.connect(admin).applySwapRouter();
        await timelockSetXomToken(vault, admin, xom.target);

        // Deposit and distribute both tokens
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

        // Bridge XOM in-kind
        await vault
          .connect(bridger)
          .bridgeToTreasury(xom.target, oddaoShare, user.address);

        // Swap USDC to XOM and bridge (with deadline)
        const dl = (await time.latest()) + 3600;
        await vault.connect(bridger).swapAndBridge(
          usdc.target, oddaoShare, 0, user.address, dl
        );

        // Both should be fully bridged
        expect(await vault.pendingBridge(xom.target)).to.equal(0n);
        expect(await vault.pendingBridge(usdc.target)).to.equal(0n);
        expect(await vault.totalBridged(xom.target)).to.equal(
          oddaoShare
        );
        expect(await vault.totalBridged(usdc.target)).to.equal(
          oddaoShare
        );
      }
    );
  });

  // ─────────────────────────────────────────────────────────────
  //  NFT MARKETPLACE ATOMIC BUY (settleNftBuy)
  // ─────────────────────────────────────────────────────────────
  describe("settleNftBuy (NFT marketplace atomic buy)", function () {
    const DOMAIN_NAME = "OmniBazaar";
    const DOMAIN_VERSION = "1";
    const INTENT_TYPES = {
      BuyNFT: [
        { name: "buyer", type: "address" },
        { name: "seller", type: "address" },
        { name: "nftContract", type: "address" },
        { name: "nftTokenId", type: "uint256" },
        { name: "paymentToken", type: "address" },
        { name: "paymentAmount", type: "uint256" },
        { name: "receiveToken", type: "address" },
        { name: "minReceiveAmount", type: "uint256" },
        { name: "swapPathHash", type: "bytes32" },
        { name: "listingId", type: "uint256" },
        { name: "referrer", type: "address" },
        { name: "referrer2", type: "address" },
        { name: "expiresAt", type: "uint256" },
        { name: "nonce", type: "uint256" }
      ]
    };

    /**
     * Deploy a fresh test context: vault with NFT settlement
     * initializer run, xomToken wired, MockERC721 deployed,
     * EIP-712 domain ready, and signer aliases attached.
     */
    async function deployNftFixture() {
      const signers = await ethers.getSigners();
      const lAdmin = signers[0];
      const lStakingPool = signers[1];
      const lProtocolTreasury = signers[2];
      const lBuyer = signers[3];
      const lSeller = signers[4];
      const lReferrer = signers[5];
      const lReferrer2 = signers[6];
      const lOther = signers[7];

      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const lXom = await MockERC20.deploy("OmniCoin", "XOM");
      await lXom.waitForDeployment();

      const Vault = await getLinkedVaultFactory();
      const lVault = await upgrades.deployProxy(
        Vault,
        [
          lAdmin.address,
          lStakingPool.address,
          lProtocolTreasury.address
        ],
        {
          initializer: "initialize",
          kind: "uups",
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ["constructor", "external-library-linking"]
        }
      );
      await lVault.waitForDeployment();

      // Wire NFT settlement V2 state: EIP-712 domain, swap router, and
      // the XOM allowlist + per-token min. `initializeV2` allowlists XOM
      // in `supportedPaymentTokens` (the coin-agnostic settlement gate)
      // — the legacy `proposeXomToken` setter only sets `xomToken`, so
      // every same-token NFT buy would otherwise revert `UnsupportedToken`.
      const MockRouter = await ethers.getContractFactory(
        "MockOmniSwapRouter"
      );
      const lRouter = await MockRouter.deploy(ethers.parseEther("1"));
      await lRouter.waitForDeployment();
      await lVault.connect(lAdmin).initializeV2(lRouter.target, lXom.target);

      const MockERC721 = await ethers.getContractFactory("MockERC721");
      const lNft = await MockERC721.deploy("TestNFT", "TNFT");
      await lNft.waitForDeployment();

      const network = await ethers.provider.getNetwork();
      const domain = {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chainId: network.chainId,
        verifyingContract: lVault.target
      };

      return {
        admin: lAdmin,
        stakingPool: lStakingPool,
        protocolTreasury: lProtocolTreasury,
        buyer: lBuyer,
        seller: lSeller,
        referrer: lReferrer,
        referrer2: lReferrer2,
        other: lOther,
        xom: lXom,
        vault: lVault,
        nft: lNft,
        domain
      };
    }

    /**
     * Build a canonical intent. Overrides merge shallowly.
     */
    async function buildIntent(ctx, overrides = {}) {
      const now = (await ethers.provider.getBlock("latest")).timestamp;
      return {
        buyer: ctx.buyer.address,
        seller: ctx.seller.address,
        nftContract: ctx.nft.target,
        nftTokenId: 1n,
        paymentToken: ctx.xom.target,
        paymentAmount: ethers.parseEther("1000"),
        receiveToken: ctx.xom.target,
        minReceiveAmount: ethers.parseEther("900"),
        swapPathHash: ethers.ZeroHash,
        listingId: 42n,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress,
        expiresAt: BigInt(now + 3600),
        nonce: 1n,
        ...overrides
      };
    }

    /**
     * Sign an intent via EIP-712.
     */
    async function signIntent(signer, domain, intent) {
      return signer.signTypedData(domain, INTENT_TYPES, intent);
    }

    const SELLER_AUTH_TYPES = {
      SellerNftSale: [
        { name: "seller", type: "address" },
        { name: "nftContract", type: "address" },
        { name: "nftTokenId", type: "uint256" },
        { name: "receiveToken", type: "address" },
        { name: "minReceiveAmount", type: "uint256" },
        { name: "expiresAt", type: "uint256" },
        { name: "nonce", type: "uint256" }
      ]
    };

    /**
     * Monotonically increasing counter backing `buildSellerAuth`'s
     * default `nonce`. Replay protection is now a per-item nonce FLOOR
     * (`_sellerNftNonceFloor`), not a used-digest boolean —
     * `settleNftBuy` requires `auth.nonce > floor` then raises `floor`
     * to `auth.nonce`. Each test in this suite deploys its own fresh
     * `ctx` (fresh vault + NFT contract) via `deployNftFixture`, so a
     * single shared counter never collides across tests; a plain
     * increment is enough to guarantee any single test's auth(s) are
     * strictly increasing.
     */
    let sellerAuthNonceSeq = 0n;

    /**
     * Build a `SellerNftSale` authorization matching a given buyer
     * `intent` by default (M-06 fix, nonce-floor revision) — mirrors
     * `buildIntent`'s style. `overrides` applied shallowly on top of
     * the intent-derived defaults. Defaults `nonce` to the next value
     * of `sellerAuthNonceSeq`.
     */
    function buildSellerAuth(intent, overrides = {}) {
      sellerAuthNonceSeq += 1n;
      return {
        seller: intent.seller,
        nftContract: intent.nftContract,
        nftTokenId: intent.nftTokenId,
        receiveToken: intent.receiveToken,
        minReceiveAmount: intent.minReceiveAmount,
        expiresAt: intent.expiresAt,
        nonce: sellerAuthNonceSeq,
        ...overrides
      };
    }

    /**
     * Sign a `SellerNftSale` authorization via EIP-712. Mirrors
     * `signIntent` — same domain (name "OmniBazaar", version "1"),
     * different type table.
     */
    async function signSellerAuth(signer, domain, auth) {
      return signer.signTypedData(domain, SELLER_AUTH_TYPES, auth);
    }

    /**
     * Prepare: mint XOM to buyer, approve vault; mint NFT to
     * seller, approve vault as operator.
     */
    async function preparePrereqs(ctx, intent) {
      await ctx.xom.mint(intent.buyer, intent.paymentAmount);
      await ctx.xom
        .connect(ctx.buyer)
        .approve(ctx.vault.target, intent.paymentAmount);
      await ctx.nft.mint(intent.seller, intent.nftTokenId);
      await ctx.nft
        .connect(ctx.seller)
        .setApprovalForAll(ctx.vault.target, true);
    }

    // ─── HAPPY PATHS ───────────────────────────────────────────
    describe("Happy paths", function () {
      it("atomically moves XOM + NFT + fee in one tx", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx);
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

        const fee = intent.paymentAmount / 100n;
        const sellerPay = intent.paymentAmount - fee;

        await expect(
          ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.emit(ctx.vault, "NFTBought");

        expect(await ctx.xom.balanceOf(ctx.buyer.address)).to.equal(
          0n
        );
        expect(await ctx.xom.balanceOf(ctx.seller.address)).to.equal(
          sellerPay
        );
        const stakingBal = await ctx.xom.balanceOf(
          ctx.stakingPool.address
        );
        const protocolBal = await ctx.xom.balanceOf(
          ctx.protocolTreasury.address
        );
        const vaultBal = await ctx.xom.balanceOf(ctx.vault.target);
        expect(vaultBal + stakingBal + protocolBal).to.equal(fee);
        expect(await ctx.nft.ownerOf(intent.nftTokenId)).to.equal(
          ctx.buyer.address
        );
      });

      it("routes 70% of referral component to referrer", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx, {
          referrer: ctx.referrer.address
        });
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

        await ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);

        const fee = intent.paymentAmount / 100n;
        const refFee = fee / 2n;
        const refPrimary = (refFee * 7000n) / 10000n;
        expect(
          await ctx.vault.pendingClaims(
            ctx.referrer.address,
            ctx.xom.target
          )
        ).to.equal(refPrimary);
      });

      it("also credits referrer2 with 20% secondary share", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx, {
          referrer: ctx.referrer.address,
          referrer2: ctx.referrer2.address
        });
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

        await ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);

        const fee = intent.paymentAmount / 100n;
        const refFee = fee / 2n;
        const refPrimary = (refFee * 7000n) / 10000n;
        const refSecondary = (refFee * 2000n) / 10000n;

        expect(
          await ctx.vault.pendingClaims(
            ctx.referrer.address,
            ctx.xom.target
          )
        ).to.equal(refPrimary);
        expect(
          await ctx.vault.pendingClaims(
            ctx.referrer2.address,
            ctx.xom.target
          )
        ).to.equal(refSecondary);
      });

      it("routes the full referral component to ODDAO when no referrer",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

          await ctx.vault
            .connect(ctx.other)
            .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);

          expect(
            await ctx.vault.pendingClaims(
              ctx.referrer.address,
              ctx.xom.target
            )
          ).to.equal(0n);
          expect(
            await ctx.vault.pendingClaims(
              ctx.referrer2.address,
              ctx.xom.target
            )
          ).to.equal(0n);
          const fee = intent.paymentAmount / 100n;
          const stakingBal = await ctx.xom.balanceOf(
            ctx.stakingPool.address
          );
          const protocolBal = await ctx.xom.balanceOf(
            ctx.protocolTreasury.address
          );
          const vaultBal = await ctx.xom.balanceOf(
            ctx.vault.target
          );
          expect(vaultBal + stakingBal + protocolBal).to.equal(fee);
        });

      it("fee math: 1% of 1000 XOM = 10 XOM fee, seller gets 990",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            paymentAmount: ethers.parseEther("1000")
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

          await ctx.vault
            .connect(ctx.other)
            .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);

          expect(await ctx.xom.balanceOf(ctx.seller.address)).to.equal(
            ethers.parseEther("990")
          );
          const vaultBal = await ctx.xom.balanceOf(ctx.vault.target);
          const stakingBal = await ctx.xom.balanceOf(
            ctx.stakingPool.address
          );
          const treasuryBal = await ctx.xom.balanceOf(
            ctx.protocolTreasury.address
          );
          expect(vaultBal + stakingBal + treasuryBal).to.equal(
            ethers.parseEther("10")
          );
          expect(
            await ctx.vault.totalDistributed(ctx.xom.target)
          ).to.equal(ethers.parseEther("10"));
        });

      it("reports happy-path gas (<= 400k)", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx);
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

        const tx = await ctx.vault
          .connect(ctx.other)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
        const rcpt = await tx.wait();
        // Merged into the vault: same pull + split + seller + NFT +
        // event emission. 400k budget leaves headroom for vault
        // overhead (vs the standalone settlement contract's 350k).
        expect(rcpt.gasUsed).to.be.lt(400_000n);
      });
    });

    // ─── SIGNATURE / REPLAY ────────────────────────────────────
    describe("Signature / replay protection", function () {
      it("reverts when signature comes from a different address",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.other, ctx.domain, intent);
          const sellerAuth = buildSellerAuth(intent);
          const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault
              .connect(ctx.other)
              .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadSigner");
        });

      it("reverts when intent is tampered with after signing",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          const tampered = { ...intent, paymentAmount: intent.paymentAmount - 1n };
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(tampered, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadSigner");
        });

      it("reverts when signature is for a different chainId",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          const badDomain = {
            ...ctx.domain,
            chainId: BigInt(ctx.domain.chainId) + 1n
          };
          const sig = await signIntent(ctx.buyer, badDomain, intent);
          const sellerAuth = buildSellerAuth(intent);
          const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault
              .connect(ctx.other)
              .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadSigner");
        });

      it("reverts when signature is for a different verifyingContract",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          const badDomain = {
            ...ctx.domain,
            verifyingContract: ctx.other.address
          };
          const sig = await signIntent(ctx.buyer, badDomain, intent);
          const sellerAuth = buildSellerAuth(intent);
          const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault
              .connect(ctx.other)
              .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadSigner");
        });

      it("replay: same intent reverts on second use (SellerAuthorizationUsed, M-06)", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx);
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
        await ctx.vault
          .connect(ctx.other)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);

        // Re-prepare so the revert comes from a replay guard.
        await ctx.xom.mint(ctx.buyer.address, intent.paymentAmount);
        await ctx.xom
          .connect(ctx.buyer)
          .approve(ctx.vault.target, intent.paymentAmount);
        await ctx.nft.mint(ctx.seller.address, intent.nftTokenId + 1n);

        // Under the M-06 fix, the single-use seller-consent gate is
        // checked BEFORE the buyer-intent replay guard, so resubmitting
        // the identical tuple now hits `SellerAuthorizationUsed` first
        // rather than the buyer-side `Replay` this test originally
        // exercised. Nonce-floor revision: the first fill raised the
        // item's `_sellerNftNonceFloor` to exactly `sellerAuth.nonce`,
        // so resubmitting the SAME auth means `auth.nonce <= floor`
        // (equal) — same revert, now via the floor comparison rather
        // than a used-digest boolean.
        await expect(
          ctx.vault
            .connect(ctx.other)
            .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.revertedWithCustomError(ctx.vault, "SellerAuthorizationUsed");
      });

      it("isNftIntentUsed reports the digest as consumed",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          // M-05: the `hashNftIntent` external view was removed for
          // code size — compute the identical EIP-712 digest locally.
          const digest = ethers.TypedDataEncoder.hash(
            ctx.domain,
            INTENT_TYPES,
            intent
          );
          expect(await ctx.vault.isNftIntentUsed(digest)).to.equal(
            false
          );
          await ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
          expect(await ctx.vault.isNftIntentUsed(digest)).to.equal(
            true
          );
        });
    });

    // ─── EXPIRY ────────────────────────────────────────────────
    describe("Expiry", function () {
      it("reverts when expiresAt is in the past", async function () {
        const ctx = await deployNftFixture();
        const now = (await ethers.provider.getBlock("latest")).timestamp;
        const intent = await buildIntent(ctx, {
          expiresAt: BigInt(now - 1)
        });
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
        await expect(
          ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.revertedWithCustomError(ctx.vault, "Expired");
      });

      it("reverts when expiresAt equals current block timestamp",
        async function () {
          const ctx = await deployNftFixture();
          const now = (await ethers.provider.getBlock("latest")).timestamp;
          const intent = await buildIntent(ctx, {
            expiresAt: BigInt(now + 5)
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await time.increaseTo(Number(intent.expiresAt));
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "Expired");
        });
    });

    // ─── PREREQUISITES ─────────────────────────────────────────
    describe("Prerequisites", function () {
      it("reverts when buyer has not approved XOM", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx);
        await ctx.xom.mint(intent.buyer, intent.paymentAmount);
        // skip XOM approve
        await ctx.nft.mint(intent.seller, intent.nftTokenId);
        await ctx.nft
          .connect(ctx.seller)
          .setApprovalForAll(ctx.vault.target, true);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
        await expect(
          ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.reverted;
      });

      it("reverts when seller has not approved the NFT",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await ctx.xom.mint(intent.buyer, intent.paymentAmount);
          await ctx.xom
            .connect(ctx.buyer)
            .approve(ctx.vault.target, intent.paymentAmount);
          await ctx.nft.mint(intent.seller, intent.nftTokenId);
          // skip NFT approve
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.reverted;
        });

      it("reverts when buyer has insufficient XOM balance",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await ctx.xom.mint(intent.buyer, intent.paymentAmount - 1n);
          await ctx.xom
            .connect(ctx.buyer)
            .approve(ctx.vault.target, intent.paymentAmount);
          await ctx.nft.mint(intent.seller, intent.nftTokenId);
          await ctx.nft
            .connect(ctx.seller)
            .setApprovalForAll(ctx.vault.target, true);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.reverted;
        });

      it("reverts when seller no longer owns the NFT",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx);
          await preparePrereqs(ctx, intent);
          await ctx.nft
            .connect(ctx.seller)
            .transferFrom(
              ctx.seller.address,
              ctx.other.address,
              intent.nftTokenId
            );
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.reverted;
        });
    });

    // ─── EDGE CASES ────────────────────────────────────────────
    describe("Edge cases", function () {
      it("reverts on zero price", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx, { paymentAmount: 0n });
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
        await expect(
          ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.revertedWithCustomError(ctx.vault, "ZeroAmount");
      });

      it("reverts on self-buy (buyer == seller)", async function () {
        const ctx = await deployNftFixture();
        const intent = await buildIntent(ctx, {
          seller: ctx.buyer.address
        });
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        // intent.seller is overridden to the buyer's own address, so
        // the seller-consent gate must be signed by ctx.buyer (not
        // ctx.seller) to pass and let the SelfBuy check fire.
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.buyer, ctx.domain, sellerAuth);
        await expect(
          ctx.vault
            .connect(ctx.other)
            .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.revertedWithCustomError(ctx.vault, "SelfBuy");
      });

      it("reverts when paymentToken is not allowlisted", async function () {
        const ctx = await deployNftFixture();
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const otherTok = await MockERC20.deploy("Other", "OTH");
        await otherTok.waitForDeployment();
        const intent = await buildIntent(ctx, {
          paymentToken: otherTok.target
        });
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
        await expect(
          ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.revertedWithCustomError(ctx.vault, "UnsupportedToken");
      });

      it("reverts when paused", async function () {
        const ctx = await deployNftFixture();
        await ctx.vault.connect(ctx.admin).pause();
        const intent = await buildIntent(ctx);
        await preparePrereqs(ctx, intent);
        const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
        await expect(
          ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
        ).to.be.revertedWithCustomError(ctx.vault, "EnforcedPause");
      });

      it("reverts for prices whose 1% rounds to zero",
        async function () {
          const ctx = await deployNftFixture();
          // paymentAmount 99 -> fee = 99/100 = 0. The coin-agnostic
          // settlement primitive rejects a zero fee (zero-fee spam guard)
          // with SaleAmountTooSmall.
          const intent = await buildIntent(ctx, { paymentAmount: 99n });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "SaleAmountTooSmall");
        });

      it("reentrancy attempt from NFT transfer hook is blocked",
        async function () {
          const ctx = await deployNftFixture();
          const ReentrantNFT = await ethers.getContractFactory(
            "ReentrantNFT"
          );
          const reNft = await ReentrantNFT.deploy();
          await reNft.waitForDeployment();
          await reNft.mint(ctx.seller.address, 1n);
          await reNft
            .connect(ctx.seller)
            .setApprovalForAll(ctx.vault.target, true);

          const intent = await buildIntent(ctx, {
            nftContract: reNft.target,
            nftTokenId: 1n,
            nonce: 7n
          });
          await ctx.xom.mint(ctx.buyer.address, intent.paymentAmount);
          await ctx.xom
            .connect(ctx.buyer)
            .approve(ctx.vault.target, intent.paymentAmount);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
          const sellerAuth = buildSellerAuth(intent);
          const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);

          await reNft.arm(ctx.vault.target, intent, sig, sellerAuth, sellerSig);

          await ctx.vault
            .connect(ctx.other)
            .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
          expect(await reNft.attempted()).to.equal(true);
          const err = await reNft.lastError();
          // Inner call must have been rejected (guard or replay).
          expect(err.length).to.be.greaterThan(0);
        });

      it("reverts when buyer is a non-ERC721-receiver contract",
        async function () {
          const ctx = await deployNftFixture();
          const Non = await ethers.getContractFactory(
            "NonERC721Receiver"
          );
          const nonRx = await Non.deploy();
          await nonRx.waitForDeployment();

          // Contract buyer with no EIP-1271 support cannot match
          // the ECDSA-recovered signer, so we assert BadSigner.
          const intent = await buildIntent(ctx, {
            buyer: nonRx.target
          });
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadSigner");
        });

      // ─── H-01 anti-fee-wash referrer identity constraints ───
      it("reverts BadReferrer when referrer == buyer",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            referrer: ctx.buyer.address
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadReferrer");
        });

      it("reverts BadReferrer when referrer == seller",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            referrer: ctx.seller.address
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadReferrer");
        });

      it("reverts BadReferrer when referrer2 == buyer",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            referrer: ctx.referrer.address,
            referrer2: ctx.buyer.address
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadReferrer");
        });

      it("reverts BadReferrer when referrer2 == seller",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            referrer: ctx.referrer.address,
            referrer2: ctx.seller.address
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadReferrer");
        });

      it("reverts BadReferrer when referrer2 == referrer",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            referrer: ctx.referrer.address,
            referrer2: ctx.referrer.address
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadReferrer");
        });

      it("accepts two distinct non-colliding referrers",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            referrer: ctx.referrer.address,
            referrer2: ctx.referrer2.address
          });
          await preparePrereqs(ctx, intent);
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await ctx.vault
            .connect(ctx.other)
            .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
          const fee = intent.paymentAmount / 100n;
          const refFee = fee / 2n;
          const refPrimary = (refFee * 7000n) / 10000n;
          const refSecondary = (refFee * 2000n) / 10000n;
          expect(
            await ctx.vault.pendingClaims(
              ctx.referrer.address,
              ctx.xom.target
            )
          ).to.equal(refPrimary);
          expect(
            await ctx.vault.pendingClaims(
              ctx.referrer2.address,
              ctx.xom.target
            )
          ).to.equal(refSecondary);
        });

      it("reverts if zero-address buyer is provided",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            buyer: ethers.ZeroAddress
          });
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "ZeroAddress");
        });

      it("reverts BadSellerAttestation if zero-address seller is provided (M-06: no signer can attest as address(0))",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            seller: ethers.ZeroAddress
          });
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
          // Under the M-06 fix, the seller-consent gate runs BEFORE
          // `validateIntent`'s ZeroAddress guard. No real ECDSA
          // signature ever recovers to address(0), so a zero seller
          // can never produce a matching `sellerAuth` signer.
          const sellerAuth = buildSellerAuth(intent);
          const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault
              .connect(ctx.other)
              .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "BadSellerAttestation");
        });

      it("reverts if zero-address nftContract is provided",
        async function () {
          const ctx = await deployNftFixture();
          const intent = await buildIntent(ctx, {
            nftContract: ethers.ZeroAddress
          });
          const sig = await signIntent(ctx.buyer, ctx.domain, intent);
        const sellerAuth = buildSellerAuth(intent);
        const sellerSig = await signSellerAuth(ctx.seller, ctx.domain, sellerAuth);
          await expect(
            ctx.vault.connect(ctx.other).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
          ).to.be.revertedWithCustomError(ctx.vault, "ZeroAddress");
        });
    });

    // ─── EIP-712 WIRING ────────────────────────────────────────
    describe("EIP-712 wiring", function () {
      it("typehash matches the canonical string byte-for-byte",
        async function () {
          const ctx = await deployNftFixture();
          const expected = ethers.keccak256(
            ethers.toUtf8Bytes(
              "BuyNFT(address buyer,address seller,address nftContract," +
                "uint256 nftTokenId,address paymentToken,uint256 paymentAmount," +
                "address receiveToken,uint256 minReceiveAmount," +
                "bytes32 swapPathHash,uint256 listingId,address referrer," +
                "address referrer2,uint256 expiresAt,uint256 nonce)"
            )
          );
          expect(await ctx.vault.BUY_NFT_TYPEHASH()).to.equal(expected);
        });

      it("BUY_NFT_DOMAIN_SEPARATOR is a 32-byte hash", async function () {
        const ctx = await deployNftFixture();
        const ds = await ctx.vault.BUY_NFT_DOMAIN_SEPARATOR();
        expect(ds).to.be.a("string");
        expect(ds.length).to.equal(66);
      });
    });
  });
});
