const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * Focused coverage for the OmniBridge refund double-spend remediation:
 * `refundTransfer` is now ADMIN_ROLE-attested rather than a trustless,
 * time-only self-service path. A sender can no longer reclaim locked source
 * funds after the destination has already released them.
 *
 * This suite deploys only OmniCoin + OmniCore + OmniBridge (no PrivateOmniCoin)
 * because the non-private refund path uses the OMNICOIN service exclusively;
 * the shared OmniBridge.test.js harness is currently blocked on an unrelated,
 * pre-existing PrivateOmniCoin deployProxy upgrade-safety failure.
 */
describe("OmniBridge refund (ADMIN_ROLE-attested)", function () {
  let owner, user1, user2, admin;
  let token, core, bridge;

  const CHAIN_ID_FUJI = 43113;
  const BLOCKCHAIN_ID_FUJI = ethers.id("fuji");
  const MIN_TRANSFER = ethers.parseEther("10");
  const MAX_TRANSFER = ethers.parseEther("10000");
  const DAILY_LIMIT = ethers.parseEther("100000");
  const TRANSFER_FEE = 50; // 0.5%
  const SEVEN_DAYS = 7 * 24 * 60 * 60;
  const WARP_MESSENGER_ADDRESS = "0x0200000000000000000000000000000000000005";

  beforeEach(async function () {
    [owner, user1, user2, admin] = await ethers.getSigners();

    // Install the MockWarpMessenger at the Warp precompile address BEFORE
    // deploying OmniBridge — initialize() reads the blockchain ID from it.
    const MockWarpMessenger = await ethers.getContractFactory("MockWarpMessenger");
    const mockWarp = await MockWarpMessenger.deploy();
    const mockCode = await ethers.provider.getCode(mockWarp.target);
    await ethers.provider.send("hardhat_setCode", [WARP_MESSENGER_ADDRESS, mockCode]);
    const mockBlockchainId = await ethers.provider.getStorage(mockWarp.target, 0);
    await ethers.provider.send("hardhat_setStorageAt", [
      WARP_MESSENGER_ADDRESS,
      "0x0",
      mockBlockchainId,
    ]);

    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy(ethers.ZeroAddress);
    await token.initialize();

    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await upgrades.deployProxy(
      OmniCore,
      [admin.address, token.target, admin.address, admin.address, admin.address],
      { initializer: "initialize", constructorArgs: [ethers.ZeroAddress] }
    );

    // Non-private path only needs the OMNICOIN service. Register PRIVATE_OMNICOIN
    // to the same token as a harmless placeholder.
    await core.connect(admin).setService(ethers.id("OMNICOIN"), token.target);
    await core.connect(admin).setService(ethers.id("PRIVATE_OMNICOIN"), token.target);

    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    bridge = await upgrades.deployProxy(
      OmniBridge,
      [core.target, admin.address],
      { initializer: "initialize", kind: "uups", constructorArgs: [ethers.ZeroAddress] }
    );

    await token.transfer(user1.address, ethers.parseEther("100000"));
    await token.transfer(user2.address, ethers.parseEther("100000"));
    await token.connect(user1).approve(bridge.target, ethers.parseEther("100000"));
    await token.connect(user2).approve(bridge.target, ethers.parseEther("100000"));

    await bridge.connect(admin).updateChainConfig(
      CHAIN_ID_FUJI,
      BLOCKCHAIN_ID_FUJI,
      true,
      MIN_TRANSFER,
      MAX_TRANSFER,
      DAILY_LIMIT,
      TRANSFER_FEE,
      ethers.ZeroAddress
    );
  });

  /** Lock a transfer (id 1) from user1 and advance past REFUND_DELAY. */
  async function lockAndElapse() {
    await bridge.connect(user1).initiateTransfer(
      user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
    );
    await time.increase(SEVEN_DAYS + 1);
  }

  it("rejects a refund from the original sender (the closed double-spend path)", async function () {
    await lockAndElapse();
    await expect(
      bridge.connect(user1).refundTransfer(1)
    ).to.be.revertedWithCustomError(bridge, "UnauthorizedSender");
  });

  it("rejects a refund from an unrelated non-admin account", async function () {
    await lockAndElapse();
    await expect(
      bridge.connect(user2).refundTransfer(1)
    ).to.be.revertedWithCustomError(bridge, "UnauthorizedSender");
  });

  it("lets ADMIN_ROLE refund after the delay, returning funds to the original sender", async function () {
    const amount = ethers.parseEther("100");
    const fee = (amount * BigInt(TRANSFER_FEE)) / 10000n;
    const netAmount = amount - fee;

    await bridge.connect(user1).initiateTransfer(
      user2.address, amount, CHAIN_ID_FUJI, false
    );
    const balanceBefore = await token.balanceOf(user1.address);
    await time.increase(SEVEN_DAYS + 1);

    await expect(bridge.connect(admin).refundTransfer(1))
      .to.emit(bridge, "TransferRefunded")
      .withArgs(1, user1.address, netAmount);

    const balanceAfter = await token.balanceOf(user1.address);
    expect(balanceAfter - balanceBefore).to.equal(netAmount);
    // TransferStatus.REFUNDED == 2
    expect(await bridge.transferStatus(1)).to.equal(2);
  });

  it("rejects an admin refund before REFUND_DELAY elapses", async function () {
    await bridge.connect(user1).initiateTransfer(
      user2.address, ethers.parseEther("100"), CHAIN_ID_FUJI, false
    );
    await time.increase(6 * 24 * 60 * 60); // only 6 days
    await expect(
      bridge.connect(admin).refundTransfer(1)
    ).to.be.revertedWithCustomError(bridge, "TransferTooEarly");
  });

  it("rejects a double refund", async function () {
    await lockAndElapse();
    await bridge.connect(admin).refundTransfer(1);
    await expect(
      bridge.connect(admin).refundTransfer(1)
    ).to.be.revertedWithCustomError(bridge, "TransferAlreadyCompleted");
  });

  it("rejects a refund for a non-existent transfer", async function () {
    await expect(
      bridge.connect(admin).refundTransfer(999)
    ).to.be.revertedWithCustomError(bridge, "TransferNotFound");
  });
});
