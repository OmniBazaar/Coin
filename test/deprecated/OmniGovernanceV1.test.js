const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniGovernanceV1", function () {
  let governance;
  let core;
  let token;
  let owner, proposer, voter1, voter2, voter3;

  const PROPOSAL_THRESHOLD = ethers.parseEther("10000"); // 10k tokens to propose
  const VOTING_DELAY = 1 * 24 * 60 * 60; // 1 day
  const VOTING_PERIOD = 3 * 24 * 60 * 60; // 3 days
  const QUORUM_PERCENTAGE = 400; // 4% quorum in basis points

  beforeEach(async function () {
    [owner, proposer, voter1, voter2, voter3] = await ethers.getSigners();

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

    // Register OmniCoin service in core (needed by governance getService)
    await core.setService(ethers.id("OMNICOIN"), token.target);

    // Grant MINTER_ROLE to core so staking transfers work
    await token.grantRole(await token.MINTER_ROLE(), core.target);

    // Deploy OmniGovernance
    const OmniGovernance = await ethers.getContractFactory("OmniGovernanceV1");
    governance = await OmniGovernance.deploy(core.target);

    // Setup: Distribute tokens
    await token.mint(proposer.address, ethers.parseEther("15000"));
    await token.mint(voter1.address, ethers.parseEther("30000"));
    await token.mint(voter2.address, ethers.parseEther("25000"));
    await token.mint(voter3.address, ethers.parseEther("30000"));

    // Total supply: 1B initial + 100k minted
  });

  describe("Proposal Creation", function () {
    it("Should create proposal with sufficient tokens", async function () {
      const description = "Mint 1000 tokens to owner";
      const proposalHash = ethers.id(description);

      const tx = await governance.connect(proposer).propose(proposalHash);

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      );

      expect(event).to.not.be.undefined;
      const proposalId = event.args.proposalId;

      const proposal = await governance.proposals(proposalId);
      expect(proposal.proposalHash).to.equal(proposalHash);
      expect(proposal.forVotes).to.equal(0);
      expect(proposal.againstVotes).to.equal(0);
      expect(proposal.executed).to.be.false;
    });

    it("Should record snapshotBlock at proposal creation", async function () {
      const proposalHash = ethers.id("Snapshot test");

      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      const proposal = await governance.proposals(proposalId);
      // snapshotBlock should be the block the proposal was created in
      expect(proposal.snapshotBlock).to.equal(receipt.blockNumber);
    });

    it("Should set startTime with voting delay", async function () {
      const proposalHash = ethers.id("Delay test");

      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      const proposal = await governance.proposals(proposalId);
      // startTime should be creation timestamp + VOTING_DELAY (1 day)
      expect(proposal.startTime).to.equal(block.timestamp + VOTING_DELAY);
      // endTime should be startTime + VOTING_PERIOD (3 days)
      expect(proposal.endTime).to.equal(
        block.timestamp + VOTING_DELAY + VOTING_PERIOD
      );
    });

    it("Should reject proposal from user with insufficient tokens", async function () {
      const description = "Test proposal";
      const proposalHash = ethers.id(description);

      // Create a new account with no tokens
      const [,,,,, noTokenUser] = await ethers.getSigners();

      await expect(
        governance.connect(noTokenUser).propose(proposalHash)
      ).to.be.revertedWithCustomError(governance, "InsufficientBalance");
    });

    it("Should track proposal count", async function () {
      const proposalHash1 = ethers.id("Proposal 1");
      const proposalHash2 = ethers.id("Proposal 2");

      await governance.connect(proposer).propose(proposalHash1);
      expect(await governance.proposalCount()).to.equal(1);

      await governance.connect(proposer).propose(proposalHash2);
      expect(await governance.proposalCount()).to.equal(2);
    });

    it("Should not allow voting before voting delay elapses", async function () {
      const proposalHash = ethers.id("Early vote test");

      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Attempt to vote immediately (before VOTING_DELAY)
      await expect(
        governance.connect(voter1).vote(proposalId, 1)
      ).to.be.revertedWithCustomError(governance, "ProposalNotActive");

      // Advance halfway through the delay - still should fail
      await time.increase(VOTING_DELAY / 2);
      await expect(
        governance.connect(voter1).vote(proposalId, 1)
      ).to.be.revertedWithCustomError(governance, "ProposalNotActive");
    });
  });

  describe("Voting", function () {
    let proposalId;

    beforeEach(async function () {
      // Create a proposal
      const proposalHash = ethers.id("Test proposal");

      const tx = await governance.connect(proposer).propose(proposalHash);

      const receipt = await tx.wait();
      proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past the voting delay so voting is active
      await time.increase(VOTING_DELAY + 1);
    });

    it("Should allow voting after delay period", async function () {
      await governance.connect(voter1).vote(proposalId, 1); // 1 = For

      const proposal = await governance.proposals(proposalId);
      expect(proposal.forVotes).to.equal(ethers.parseEther("30000"));

      const hasVoted = await governance.hasVoted(proposalId, voter1.address);
      expect(hasVoted).to.be.true;
    });

    it("Should count votes correctly", async function () {
      // Voter1 votes for (30k tokens)
      await governance.connect(voter1).vote(proposalId, 1); // For

      // Voter2 votes against (25k tokens)
      await governance.connect(voter2).vote(proposalId, 0); // Against

      // Voter3 votes for (30k tokens)
      await governance.connect(voter3).vote(proposalId, 1); // For

      const proposal = await governance.proposals(proposalId);
      expect(proposal.forVotes).to.equal(ethers.parseEther("60000")); // 30k + 30k
      expect(proposal.againstVotes).to.equal(ethers.parseEther("25000"));
    });

    it("Should prevent double voting", async function () {
      await governance.connect(voter1).vote(proposalId, 1);

      await expect(
        governance.connect(voter1).vote(proposalId, 0)
      ).to.be.revertedWithCustomError(governance, "AlreadyVoted");
    });

    it("Should not allow voting after period ends", async function () {
      // Already advanced VOTING_DELAY + 1 in beforeEach.
      // Advance past the remaining voting period.
      await time.increase(VOTING_PERIOD + 1);

      await expect(
        governance.connect(voter1).vote(proposalId, 1)
      ).to.be.revertedWithCustomError(governance, "ProposalNotActive");
    });
  });

  describe("Staked XOM Voting Weight", function () {
    it("Should include staked XOM in voting weight", async function () {
      // voter1 has 30k liquid tokens
      // Approve core to spend tokens for staking
      const stakeAmount = ethers.parseEther("10000");
      await token.connect(voter1).approve(core.target, stakeAmount);

      // Stake tokens (tier 1, duration 0)
      await core.connect(voter1).stake(stakeAmount, 1, 0);

      // voter1 now has 20k liquid + 10k staked = 30k total

      // Create proposal
      const proposalHash = ethers.id("Staking weight test");
      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past voting delay
      await time.increase(VOTING_DELAY + 1);

      // Vote - weight should include both liquid and staked
      await governance.connect(voter1).vote(proposalId, 1);

      const proposal = await governance.proposals(proposalId);
      // Total weight = 20k liquid + 10k staked = 30k
      expect(proposal.forVotes).to.equal(ethers.parseEther("30000"));
    });

    it("Should allow proposal creation with staked-only balance meeting threshold", async function () {
      // Create a user with exactly threshold tokens, stake all of them
      const [,,,,,, stakerOnly] = await ethers.getSigners();
      await token.mint(stakerOnly.address, ethers.parseEther("10000"));

      // Approve and stake all tokens
      await token.connect(stakerOnly).approve(core.target, ethers.parseEther("10000"));
      await core.connect(stakerOnly).stake(ethers.parseEther("10000"), 1, 0);

      // stakerOnly now has 0 liquid + 10k staked = 10k total
      // Should still be able to propose (staked counts toward threshold)
      const proposalHash = ethers.id("Staker-only proposal");
      await expect(
        governance.connect(stakerOnly).propose(proposalHash)
      ).to.not.be.reverted;
    });

    it("Should allow voting with only staked balance", async function () {
      const [,,,,,, pureStaker] = await ethers.getSigners();
      await token.mint(pureStaker.address, ethers.parseEther("5000"));

      // Stake all tokens
      await token.connect(pureStaker).approve(core.target, ethers.parseEther("5000"));
      await core.connect(pureStaker).stake(ethers.parseEther("5000"), 1, 0);

      // Create proposal (by proposer who has liquid tokens)
      const proposalHash = ethers.id("Pure staker vote test");
      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      await time.increase(VOTING_DELAY + 1);

      // pureStaker has 0 liquid but 5k staked - should be able to vote
      await governance.connect(pureStaker).vote(proposalId, 1);

      const proposal = await governance.proposals(proposalId);
      expect(proposal.forVotes).to.equal(ethers.parseEther("5000"));
    });
  });

  describe("Proposal Execution", function () {
    let proposalId;

    beforeEach(async function () {
      // Create a proposal
      const proposalHash = ethers.id("Test execution proposal");

      const tx = await governance.connect(proposer).propose(proposalHash);

      const receipt = await tx.wait();
      proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past voting delay
      await time.increase(VOTING_DELAY + 1);

      // Pass the proposal with enough votes
      // Need 4% of ~1B total supply for quorum
      await governance.connect(owner).vote(proposalId, 1); // ~1B tokens
      await governance.connect(voter1).vote(proposalId, 1); // 30k
      await governance.connect(voter2).vote(proposalId, 1); // 25k
      await governance.connect(voter3).vote(proposalId, 1); // 30k
      // Total: 1B+ for, 0 against - meets quorum

      // Wait for voting period to end
      await time.increase(VOTING_PERIOD + 1);
    });

    it("Should execute passed proposal", async function () {
      // In simplified contract, execution just marks as executed
      // Actual execution happens off-chain
      await governance.execute(proposalId);

      const proposal = await governance.proposals(proposalId);
      expect(proposal.executed).to.be.true;
    });

    it("Should not execute proposal that didn't pass", async function () {
      // Create new proposal that will fail
      const failProposalHash = ethers.id("Failing proposal");

      const tx = await governance.connect(proposer).propose(failProposalHash);

      const receipt = await tx.wait();
      const failProposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past voting delay
      await time.increase(VOTING_DELAY + 1);

      // Vote against with majority
      await governance.connect(voter1).vote(failProposalId, 0); // Against
      await governance.connect(voter2).vote(failProposalId, 0); // Against

      await time.increase(VOTING_PERIOD + 1);

      await expect(
        governance.execute(failProposalId)
      ).to.be.revertedWithCustomError(governance, "ProposalNotPassed");
    });

    it("Should not execute proposal below quorum", async function () {
      // Create new proposal with low participation
      const lowProposalHash = ethers.id("Low participation proposal");

      const tx = await governance.connect(proposer).propose(lowProposalHash);

      const receipt = await tx.wait();
      const lowProposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past voting delay
      await time.increase(VOTING_DELAY + 1);

      // Only one small voter votes
      // 4% quorum of ~1B = ~40M tokens needed
      // proposer has 15k tokens, far below quorum
      await governance.connect(proposer).vote(lowProposalId, 1);

      await time.increase(VOTING_PERIOD + 1);

      await expect(
        governance.execute(lowProposalId)
      ).to.be.revertedWithCustomError(governance, "QuorumNotReached");
    });

    it("Should prevent double execution", async function () {
      await governance.execute(proposalId);

      await expect(
        governance.execute(proposalId)
      ).to.be.revertedWithCustomError(governance, "ProposalAlreadyExecuted");
    });
  });

  describe("Proposal States", function () {
    it("Should track proposal lifecycle", async function () {
      // Create proposal
      const proposalHash = ethers.id("State test proposal");

      const tx = await governance.connect(proposer).propose(proposalHash);

      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      const proposal = await governance.proposals(proposalId);
      expect(proposal.executed).to.be.false;
      expect(proposal.canceled).to.be.false;

      // Advance past voting delay
      await time.increase(VOTING_DELAY + 1);

      // Vote to pass (need owner for quorum)
      await governance.connect(owner).vote(proposalId, 1);
      await governance.connect(voter1).vote(proposalId, 1);
      await governance.connect(voter2).vote(proposalId, 1);
      await governance.connect(voter3).vote(proposalId, 1);

      // Wait for voting to end
      await time.increase(VOTING_PERIOD + 1);

      // Execute
      await governance.execute(proposalId);

      const executedProposal = await governance.proposals(proposalId);
      expect(executedProposal.executed).to.be.true;
    });
  });

  describe("Events", function () {
    it("Should emit correct events", async function () {
      const proposalHash = ethers.id("Event test proposal");

      // ProposalCreated event
      const proposeTx = await governance.connect(proposer).propose(proposalHash);

      await expect(proposeTx).to.emit(governance, "ProposalCreated");

      const receipt = await proposeTx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past voting delay
      await time.increase(VOTING_DELAY + 1);

      // VoteCast event
      await expect(governance.connect(voter1).vote(proposalId, 1))
        .to.emit(governance, "VoteCast")
        .withArgs(proposalId, voter1.address, 1, ethers.parseEther("30000"));

      // ProposalExecuted event (need owner for quorum)
      await governance.connect(owner).vote(proposalId, 1);
      await governance.connect(voter2).vote(proposalId, 1);
      await governance.connect(voter3).vote(proposalId, 1);
      await time.increase(VOTING_PERIOD + 1);

      await expect(
        governance.execute(proposalId)
      ).to.emit(governance, "ProposalExecuted")
        .withArgs(proposalId, owner.address);
    });
  });

  describe("Flash Loan Protection", function () {
    it("Should have a 1-day voting delay constant", async function () {
      const delay = await governance.VOTING_DELAY();
      expect(delay).to.equal(VOTING_DELAY);
    });

    it("Should reject votes during the delay period", async function () {
      const proposalHash = ethers.id("Flash loan test");
      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Voting should fail immediately (within same block / before delay)
      await expect(
        governance.connect(voter1).vote(proposalId, 1)
      ).to.be.revertedWithCustomError(governance, "ProposalNotActive");
    });

    it("Should allow votes after the delay period", async function () {
      const proposalHash = ethers.id("Flash loan test 2");
      const tx = await governance.connect(proposer).propose(proposalHash);
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // Advance past the voting delay
      await time.increase(VOTING_DELAY + 1);

      // Should succeed now
      await expect(
        governance.connect(voter1).vote(proposalId, 1)
      ).to.not.be.reverted;
    });
  });
});
