const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniGovernance", function () {
  let governance;
  let token;
  let owner, proposer, voter1, voter2, voter3;
  
  const PROPOSAL_THRESHOLD = ethers.parseEther("10000"); // 10k tokens to propose
  const VOTING_PERIOD = 3 * 24 * 60 * 60; // 3 days
  const QUORUM_PERCENTAGE = 400; // 4% quorum in basis points
  
  beforeEach(async function () {
    [owner, proposer, voter1, voter2, voter3] = await ethers.getSigners();
    
    // Deploy OmniCoin token
    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy();
    await token.initialize();
    
    // Deploy OmniCore with all required constructor arguments
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const core = await OmniCore.deploy(owner.address, token.target, owner.address, owner.address);
    
    // Register OmniCoin service in core
    await core.setService(ethers.id("OMNICOIN"), token.target);
    
    // Deploy OmniGovernance
    const OmniGovernance = await ethers.getContractFactory("OmniGovernance");
    governance = await OmniGovernance.deploy(core.target);
    
    // Setup: Distribute tokens
    await token.mint(proposer.address, ethers.parseEther("15000"));
    await token.mint(voter1.address, ethers.parseEther("30000"));
    await token.mint(voter2.address, ethers.parseEther("25000"));
    await token.mint(voter3.address, ethers.parseEther("30000"));
    
    // Total supply: 100k tokens (15k + 30k + 25k + 30k)
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
    });
    
    it("Should allow voting immediately", async function () {
      // No voting delay in simplified contract
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
      await time.increase(VOTING_PERIOD + 1);
      
      await expect(
        governance.connect(voter1).vote(proposalId, 1)
      ).to.be.revertedWithCustomError(governance, "ProposalNotActive");
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
      
      // Pass the proposal with enough votes
      // Need 4% of 1B total supply = 40M votes for quorum
      await governance.connect(owner).vote(proposalId, 1); // 1B tokens
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
      
      // Only one small voter votes - need to check total supply for quorum
      // Total supply after mints: 1B initial + 300k minted = 1,000,300,000
      // 4% quorum = 40,012,000 tokens needed
      // proposer has 15k tokens, vote for
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
});