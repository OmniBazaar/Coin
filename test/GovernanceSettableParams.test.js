const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

/**
 * Settable governance-parameter tests for the OmniGovernance
 * settable-params upgrade. Verifies that votingDelay, votingPeriod,
 * proposalThreshold, and quorumBps are seeded to the founder-ratified
 * launch defaults on a fresh deploy, are adjustable only by
 * DEFAULT_ADMIN_ROLE, and are clamped to their hard min/max bounds so a
 * hostile or buggy proposal can neither zero out quorum nor brick
 * governance with unreachable values.
 */
describe("OmniGovernance — settable governance parameters", function () {
  let governance, admin, other, a1, a2, a3;

  const TWO_DAYS = 2n * 24n * 60n * 60n;
  const SEVEN_DAYS = 7n * 24n * 60n * 60n;
  const DEFAULT_THRESHOLD = ethers.parseEther("1700000");
  const DEFAULT_QUORUM_BPS = 150n;

  beforeEach(async function () {
    [admin, other, a1, a2, a3] = await ethers.getSigners();
    const Governance = await ethers.getContractFactory("OmniGovernance");
    // The setters gate only on DEFAULT_ADMIN_ROLE; omniCoin/omniCore/timelock
    // are stored but unused here, so placeholder non-zero addresses suffice.
    governance = await upgrades.deployProxy(
      Governance,
      [a1.address, a2.address, a3.address, admin.address],
      {
        initializer: "initialize",
        kind: "uups",
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ["constructor"],
      }
    );
  });

  describe("seeded launch defaults", function () {
    it("seeds the founder-ratified values on a fresh deploy", async function () {
      expect(await governance.votingDelay()).to.equal(TWO_DAYS);
      expect(await governance.votingPeriod()).to.equal(SEVEN_DAYS);
      expect(await governance.proposalThreshold()).to.equal(DEFAULT_THRESHOLD);
      expect(await governance.quorumBps()).to.equal(DEFAULT_QUORUM_BPS);
    });
  });

  describe("setVotingDelay", function () {
    it("admin updates within bounds and emits", async function () {
      await expect(governance.connect(admin).setVotingDelay(TWO_DAYS + 1n))
        .to.emit(governance, "VotingDelayUpdated")
        .withArgs(TWO_DAYS, TWO_DAYS + 1n);
      expect(await governance.votingDelay()).to.equal(TWO_DAYS + 1n);
    });
    it("reverts below MIN_VOTING_DELAY", async function () {
      const min = await governance.MIN_VOTING_DELAY();
      await expect(
        governance.connect(admin).setVotingDelay(min - 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
    it("reverts above MAX_VOTING_DELAY", async function () {
      const max = await governance.MAX_VOTING_DELAY();
      await expect(
        governance.connect(admin).setVotingDelay(max + 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
    it("reverts for non-admin", async function () {
      await expect(
        governance.connect(other).setVotingDelay(TWO_DAYS)
      ).to.be.revertedWithCustomError(
        governance,
        "AccessControlUnauthorizedAccount"
      );
    });
  });

  describe("setVotingPeriod", function () {
    it("admin updates within bounds and emits", async function () {
      await expect(governance.connect(admin).setVotingPeriod(SEVEN_DAYS + 1n))
        .to.emit(governance, "VotingPeriodUpdated")
        .withArgs(SEVEN_DAYS, SEVEN_DAYS + 1n);
      expect(await governance.votingPeriod()).to.equal(SEVEN_DAYS + 1n);
    });
    it("reverts below MIN_VOTING_PERIOD", async function () {
      const min = await governance.MIN_VOTING_PERIOD();
      await expect(
        governance.connect(admin).setVotingPeriod(min - 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
    it("reverts above MAX_VOTING_PERIOD", async function () {
      const max = await governance.MAX_VOTING_PERIOD();
      await expect(
        governance.connect(admin).setVotingPeriod(max + 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
  });

  describe("setProposalThreshold", function () {
    it("admin updates within bounds and emits", async function () {
      const next = ethers.parseEther("2000000");
      await expect(governance.connect(admin).setProposalThreshold(next))
        .to.emit(governance, "ProposalThresholdUpdated")
        .withArgs(DEFAULT_THRESHOLD, next);
      expect(await governance.proposalThreshold()).to.equal(next);
    });
    it("reverts below MIN_PROPOSAL_THRESHOLD", async function () {
      const min = await governance.MIN_PROPOSAL_THRESHOLD();
      await expect(
        governance.connect(admin).setProposalThreshold(min - 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
    it("reverts above MAX_PROPOSAL_THRESHOLD", async function () {
      const max = await governance.MAX_PROPOSAL_THRESHOLD();
      await expect(
        governance.connect(admin).setProposalThreshold(max + 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
  });

  describe("setQuorumBps", function () {
    it("admin updates within bounds and emits", async function () {
      await expect(governance.connect(admin).setQuorumBps(400n))
        .to.emit(governance, "QuorumBpsUpdated")
        .withArgs(DEFAULT_QUORUM_BPS, 400n);
      expect(await governance.quorumBps()).to.equal(400n);
    });
    it("reverts below MIN_QUORUM_BPS (cannot zero out quorum)", async function () {
      const min = await governance.MIN_QUORUM_BPS();
      await expect(
        governance.connect(admin).setQuorumBps(min - 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
    it("reverts above MAX_QUORUM_BPS (cannot brick with gridlock)", async function () {
      const max = await governance.MAX_QUORUM_BPS();
      await expect(
        governance.connect(admin).setQuorumBps(max + 1n)
      ).to.be.revertedWithCustomError(governance, "ParameterOutOfBounds");
    });
    it("reverts for non-admin", async function () {
      await expect(
        governance.connect(other).setQuorumBps(400n)
      ).to.be.revertedWithCustomError(
        governance,
        "AccessControlUnauthorizedAccount"
      );
    });
  });
});
