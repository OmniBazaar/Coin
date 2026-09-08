const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

/**
 * Voteable-supply quorum tests for the OmniGovernance voteable-quorum upgrade.
 * Verifies that the quorum denominator (snapshotTotalSupply) is totalSupply
 * minus the live balances of the configured excluded holders (undistributed
 * reward pools, unclaimed legacy, founder vest), that the excluded set is
 * DEFAULT_ADMIN_ROLE-gated + replace-semantics + zero-rejecting, and that the
 * computed voteable supply tracks excluded balances dynamically.
 */
describe("OmniGovernance — voteable-supply quorum", function () {
  let token, governance, admin, other, pool1, pool2;

  beforeEach(async function () {
    [admin, other, pool1, pool2] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy(ethers.ZeroAddress);
    await token.initialize(); // mints the full supply to the deployer (admin)

    const Governance = await ethers.getContractFactory("OmniGovernance");
    governance = await upgrades.deployProxy(
      Governance,
      // core + timelock are unused by voteableSupply; real token is what matters
      [token.target, other.address, other.address, admin.address],
      {
        initializer: "initialize",
        kind: "uups",
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ["constructor"],
      }
    );
  });

  it("voteableSupply == totalSupply when no holders are excluded", async function () {
    expect(await governance.voteableSupply()).to.equal(
      await token.totalSupply()
    );
  });

  it("subtracts excluded holder balances (dynamic)", async function () {
    await token.connect(admin).transfer(
      pool1.address,
      ethers.parseEther("1000000000")
    ); // 1B
    await token.connect(admin).transfer(
      pool2.address,
      ethers.parseEther("500000000")
    ); // 0.5B
    await governance
      .connect(admin)
      .setQuorumExcludedHolders([pool1.address, pool2.address]);

    const total = await token.totalSupply();
    expect(await governance.voteableSupply()).to.equal(
      total - ethers.parseEther("1500000000")
    );

    // Dynamic: as a pool distributes, voteable rises.
    await token.connect(pool1).transfer(
      other.address,
      ethers.parseEther("400000000")
    );
    expect(await governance.voteableSupply()).to.equal(
      total - ethers.parseEther("1100000000")
    );
  });

  it("setQuorumExcludedHolders emits, is admin-gated, rejects zero", async function () {
    await expect(
      governance.connect(admin).setQuorumExcludedHolders([pool1.address])
    )
      .to.emit(governance, "QuorumExcludedHoldersUpdated")
      .withArgs(1);
    expect(await governance.quorumExcludedHolders(0)).to.equal(pool1.address);

    await expect(
      governance.connect(other).setQuorumExcludedHolders([pool1.address])
    ).to.be.revertedWithCustomError(
      governance,
      "AccessControlUnauthorizedAccount"
    );

    await expect(
      governance.connect(admin).setQuorumExcludedHolders([ethers.ZeroAddress])
    ).to.be.revertedWithCustomError(governance, "InvalidAddress");
  });

  it("replaces (not appends) the excluded set", async function () {
    await governance
      .connect(admin)
      .setQuorumExcludedHolders([pool1.address, pool2.address]);
    await governance.connect(admin).setQuorumExcludedHolders([pool1.address]);
    expect(await governance.quorumExcludedHolders(0)).to.equal(pool1.address);
    // index 1 should no longer exist
    await expect(governance.quorumExcludedHolders(1)).to.be.reverted;
  });
});
