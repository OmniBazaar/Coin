const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

/**
 * Guardian-pause upgrade tests for OmniBridge. Verifies that any single
 * EmergencyGuardian member (1-of-N) can emergency-pause the bridge while
 * unpause stays admin-only (subtract-only guardian scope), that the
 * emergencyGuardian address is DEFAULT_ADMIN_ROLE-gated and disable-able,
 * and that the pre-existing admin pause path is unaffected.
 */
describe("OmniBridge — guardian emergency pause", function () {
  let token, core, timelock, guardian, bridge;
  let admin, owner, g1, g2, g3, g4, g5, other;

  beforeEach(async function () {
    [admin, owner, g1, g2, g3, g4, g5, other] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy(ethers.ZeroAddress);
    await token.initialize();

    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await upgrades.deployProxy(
      OmniCore,
      [admin.address, token.target, admin.address, admin.address, admin.address],
      {
        initializer: "initialize",
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ["constructor"],
      }
    );
    // Ensure admin holds core ADMIN_ROLE (the bridge admin-pause path).
    await core
      .connect(admin)
      .grantRole(await core.ADMIN_ROLE(), admin.address);

    const Timelock = await ethers.getContractFactory("OmniTimelockController");
    timelock = await Timelock.deploy(
      [owner.address],
      [ethers.ZeroAddress],
      owner.address
    );

    const Guardian = await ethers.getContractFactory("EmergencyGuardian");
    guardian = await Guardian.deploy(timelock.target, [
      g1.address,
      g2.address,
      g3.address,
      g4.address,
      g5.address,
    ]);

    // Stub the Avalanche Warp Messenger precompile (used by initialize()).
    const WARP_MESSENGER_ADDRESS =
      "0x0200000000000000000000000000000000000005";
    const MockWarpMessenger = await ethers.getContractFactory(
      "MockWarpMessenger"
    );
    const mockWarp = await MockWarpMessenger.deploy();
    const mockCode = await ethers.provider.getCode(mockWarp.target);
    await ethers.provider.send("hardhat_setCode", [
      WARP_MESSENGER_ADDRESS,
      mockCode,
    ]);
    const mockBlockchainId = await ethers.provider.getStorage(
      mockWarp.target,
      0
    );
    await ethers.provider.send("hardhat_setStorageAt", [
      WARP_MESSENGER_ADDRESS,
      "0x0",
      mockBlockchainId,
    ]);

    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    bridge = await upgrades.deployProxy(OmniBridge, [core.target, admin.address], {
      initializer: "initialize",
      kind: "uups",
      constructorArgs: [ethers.ZeroAddress],
      unsafeAllow: ["constructor"],
    });
  });

  describe("setEmergencyGuardian", function () {
    it("starts unset (address(0))", async function () {
      expect(await bridge.emergencyGuardian()).to.equal(ethers.ZeroAddress);
    });
    it("admin sets it and emits", async function () {
      await expect(bridge.connect(admin).setEmergencyGuardian(guardian.target))
        .to.emit(bridge, "EmergencyGuardianUpdated")
        .withArgs(ethers.ZeroAddress, guardian.target);
      expect(await bridge.emergencyGuardian()).to.equal(guardian.target);
    });
    it("reverts for non-admin", async function () {
      await expect(
        bridge.connect(other).setEmergencyGuardian(guardian.target)
      ).to.be.revertedWithCustomError(
        bridge,
        "AccessControlUnauthorizedAccount"
      );
    });
  });

  describe("guardian pause (1-of-N)", function () {
    beforeEach(async function () {
      await bridge.connect(admin).setEmergencyGuardian(guardian.target);
    });

    it("a single guardian can pause", async function () {
      await expect(bridge.connect(g3).pause()).to.emit(bridge, "Paused");
      expect(await bridge.paused()).to.equal(true);
    });

    it("admin can still pause (existing path unaffected)", async function () {
      await bridge.connect(admin).pause();
      expect(await bridge.paused()).to.equal(true);
    });

    it("a non-guardian non-admin cannot pause", async function () {
      await expect(
        bridge.connect(other).pause()
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });

    it("a guardian CANNOT unpause (subtract-only scope)", async function () {
      await bridge.connect(g1).pause();
      await expect(
        bridge.connect(g1).unpause()
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
      // admin can unpause
      await bridge.connect(admin).unpause();
      expect(await bridge.paused()).to.equal(false);
    });

    it("guardian path is disabled when emergencyGuardian is cleared", async function () {
      await bridge.connect(admin).setEmergencyGuardian(ethers.ZeroAddress);
      await expect(
        bridge.connect(g3).pause()
      ).to.be.revertedWithCustomError(bridge, "InvalidRecipient");
    });
  });
});
