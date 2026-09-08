/**
 * BridgedFeeCollector unit tests — hardhat local network.
 *
 * Covers:
 *   - Construction with explicit owner
 *   - Deposit (anyone sends ERC-20 → contract holds)
 *   - sweep(token, dest, amount): owner-only, pause-respecting,
 *     minSweepAmount-respecting, zero-amount + zero-dest guarded
 *   - setMinSweepAmount: owner-only
 *   - pause + unpause: owner-only, emits, blocks sweep
 *   - rescueETH: owner-only, transfers contract native balance
 *   - 2-step ownership transfer (Ownable2Step)
 */
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("BridgedFeeCollector", function () {
  let collector;
  let usdc;
  let owner;
  let user;
  let attacker;
  let destination;

  beforeEach(async function () {
    [owner, user, attacker, destination] = await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory("TestUSDC");
    usdc = await ERC20Mock.deploy();
    await usdc.waitForDeployment();

    const Factory = await ethers.getContractFactory("BridgedFeeCollector");
    collector = await Factory.deploy(owner.address);
    await collector.waitForDeployment();

    // Seed the contract with 1,000 USDC as if it had received fees.
    await usdc.transfer(await collector.getAddress(), 1_000_000_000n);
  });

  it("returns the constructor-provided owner", async function () {
    expect(await collector.owner()).to.equal(owner.address);
  });

  it("accepts ERC-20 deposits from anyone", async function () {
    // Already seeded in beforeEach; verify a SECOND deposit also lands.
    const collectorAddr = await collector.getAddress();
    await usdc.connect(owner).transfer(collectorAddr, 500_000_000n);
    expect(await usdc.balanceOf(collectorAddr)).to.equal(1_500_000_000n);
  });

  describe("sweep", function () {
    it("transfers tokens to destination when called by owner", async function () {
      const amount = 1_000_000_000n;
      const collectorAddr = await collector.getAddress();
      const balBefore = await usdc.balanceOf(destination.address);
      await expect(
        collector.connect(owner).sweep(await usdc.getAddress(), destination.address, amount),
      )
        .to.emit(collector, "Swept")
        .withArgs(await usdc.getAddress(), destination.address, amount, owner.address);
      expect(await usdc.balanceOf(destination.address)).to.equal(balBefore + amount);
      expect(await usdc.balanceOf(collectorAddr)).to.equal(0n);
    });

    it("reverts when called by non-owner", async function () {
      await expect(
        collector.connect(attacker).sweep(
          await usdc.getAddress(),
          destination.address,
          1_000_000n,
        ),
      ).to.be.revertedWithCustomError(collector, "OwnableUnauthorizedAccount");
    });

    it("reverts on zero destination", async function () {
      await expect(
        collector.connect(owner).sweep(
          await usdc.getAddress(),
          ethers.ZeroAddress,
          1_000_000n,
        ),
      ).to.be.revertedWithCustomError(collector, "ZeroDestination");
    });

    it("reverts on zero amount", async function () {
      await expect(
        collector.connect(owner).sweep(
          await usdc.getAddress(),
          destination.address,
          0n,
        ),
      ).to.be.revertedWithCustomError(collector, "ZeroAmount");
    });

    it("respects minSweepAmount floor", async function () {
      await collector
        .connect(owner)
        .setMinSweepAmount(await usdc.getAddress(), 500_000_000n);
      await expect(
        collector.connect(owner).sweep(
          await usdc.getAddress(),
          destination.address,
          499_999_999n,
        ),
      )
        .to.be.revertedWithCustomError(collector, "BelowMinSweepAmount")
        .withArgs(499_999_999n, 500_000_000n);
      // At-floor sweep succeeds.
      await expect(
        collector.connect(owner).sweep(
          await usdc.getAddress(),
          destination.address,
          500_000_000n,
        ),
      ).to.emit(collector, "Swept");
    });

    it("reverts when sweep is paused", async function () {
      await collector.connect(owner).pause();
      await expect(
        collector.connect(owner).sweep(
          await usdc.getAddress(),
          destination.address,
          1_000_000n,
        ),
      ).to.be.revertedWithCustomError(collector, "SweepIsPaused");
    });

    it("works again after unpause", async function () {
      await collector.connect(owner).pause();
      await collector.connect(owner).unpause();
      await expect(
        collector.connect(owner).sweep(
          await usdc.getAddress(),
          destination.address,
          1_000_000n,
        ),
      ).to.emit(collector, "Swept");
    });
  });

  describe("setMinSweepAmount", function () {
    it("sets the floor and emits", async function () {
      await expect(
        collector.connect(owner).setMinSweepAmount(await usdc.getAddress(), 12345n),
      )
        .to.emit(collector, "MinSweepAmountUpdated")
        .withArgs(await usdc.getAddress(), 12345n);
      expect(await collector.minSweepAmount(await usdc.getAddress())).to.equal(12345n);
    });

    it("reverts when called by non-owner", async function () {
      await expect(
        collector.connect(attacker).setMinSweepAmount(await usdc.getAddress(), 1n),
      ).to.be.revertedWithCustomError(collector, "OwnableUnauthorizedAccount");
    });
  });

  describe("rescueETH", function () {
    it("sends native balance to destination", async function () {
      const collectorAddr = await collector.getAddress();
      await user.sendTransaction({
        to: collectorAddr,
        value: ethers.parseEther("0.5"),
      });
      const destBalBefore = await ethers.provider.getBalance(destination.address);
      await expect(collector.connect(owner).rescueETH(destination.address))
        .to.emit(collector, "RescuedETH")
        .withArgs(destination.address, ethers.parseEther("0.5"));
      const destBalAfter = await ethers.provider.getBalance(destination.address);
      expect(destBalAfter - destBalBefore).to.equal(ethers.parseEther("0.5"));
      expect(await ethers.provider.getBalance(collectorAddr)).to.equal(0n);
    });

    it("reverts on zero ETH destination", async function () {
      await expect(
        collector.connect(owner).rescueETH(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(collector, "ZeroETHDestination");
    });

    it("reverts when there's no native balance", async function () {
      // collector was just deployed with no ETH (beforeEach seeds USDC only).
      await expect(
        collector.connect(owner).rescueETH(destination.address),
      ).to.be.revertedWithCustomError(collector, "ZeroAmount");
    });

    it("reverts for non-owner", async function () {
      await expect(
        collector.connect(attacker).rescueETH(destination.address),
      ).to.be.revertedWithCustomError(collector, "OwnableUnauthorizedAccount");
    });
  });

  describe("Ownable2Step", function () {
    it("requires accept step to complete transfer", async function () {
      await collector.connect(owner).transferOwnership(user.address);
      // Until acceptance, original owner still owns.
      expect(await collector.owner()).to.equal(owner.address);
      expect(await collector.pendingOwner()).to.equal(user.address);
      await collector.connect(user).acceptOwnership();
      expect(await collector.owner()).to.equal(user.address);
    });

    it("disables renounceOwnership (would permanently lock funds)", async function () {
      await expect(
        collector.connect(owner).renounceOwnership(),
      ).to.be.revertedWithCustomError(collector, "RenounceDisabled");
      // Ownership is intact after the reverted call.
      expect(await collector.owner()).to.equal(owner.address);
    });
  });

  describe("sweepAll", function () {
    it("sweeps the entire balance and emits Swept", async function () {
      const usdcAddr = await usdc.getAddress();
      const collectorAddr = await collector.getAddress();
      const bal = await usdc.balanceOf(collectorAddr);
      const balBefore = await usdc.balanceOf(destination.address);
      await expect(collector.connect(owner).sweepAll(usdcAddr, destination.address))
        .to.emit(collector, "Swept")
        .withArgs(usdcAddr, destination.address, bal, owner.address);
      expect(await usdc.balanceOf(destination.address)).to.equal(balBefore + bal);
      expect(await usdc.balanceOf(collectorAddr)).to.equal(0n);
    });

    it("reverts on zero balance", async function () {
      const usdcAddr = await usdc.getAddress();
      // Drain first, then a second sweepAll has nothing to move.
      await collector.connect(owner).sweepAll(usdcAddr, destination.address);
      await expect(
        collector.connect(owner).sweepAll(usdcAddr, destination.address),
      ).to.be.revertedWithCustomError(collector, "NothingToSweep");
    });

    it("respects the minSweepAmount floor on the full balance", async function () {
      const usdcAddr = await usdc.getAddress();
      // Floor above the balance: full-balance sweep is blocked.
      await collector.connect(owner).setMinSweepAmount(usdcAddr, 2_000_000_000n);
      await expect(
        collector.connect(owner).sweepAll(usdcAddr, destination.address),
      ).to.be.revertedWithCustomError(collector, "BelowMinSweepAmount");
    });

    it("reverts on zero destination", async function () {
      await expect(
        collector.connect(owner).sweepAll(await usdc.getAddress(), ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(collector, "ZeroDestination");
    });

    it("reverts when paused", async function () {
      await collector.connect(owner).pause();
      await expect(
        collector.connect(owner).sweepAll(await usdc.getAddress(), destination.address),
      ).to.be.revertedWithCustomError(collector, "SweepIsPaused");
    });

    it("reverts when called by non-owner", async function () {
      await expect(
        collector.connect(attacker).sweepAll(await usdc.getAddress(), destination.address),
      ).to.be.revertedWithCustomError(collector, "OwnableUnauthorizedAccount");
    });
  });
});
