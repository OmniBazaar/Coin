const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinGovernor", function () {
    let owner, proposer, voter1, voter2, voter3, voter4, treasury, user;
    let registry, omniCoin, privateOmniCoin;
    let governor;
    let testTarget;
    
    // Constants
    const DEFAULT_VOTING_PERIOD = 3 * 24 * 60 * 60; // 3 days
    const DEFAULT_PROPOSAL_THRESHOLD = ethers.parseUnits("1000", 6);
    const DEFAULT_QUORUM = ethers.parseUnits("10000", 6);
    
    // Vote types
    const VoteType = {
        Against: 0,
        For: 1,
        Abstain: 2
    };
    
    beforeEach(async function () {
        [owner, proposer, voter1, voter2, voter3, voter4, treasury, user] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test
        const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        privateOmniCoin = await StandardERC20Test.deploy();
        await privateOmniCoin.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        
        // Deploy OmniCoinGovernor
        const OmniCoinGovernor = await ethers.getContractFactory("OmniCoinGovernor");
        governor = await OmniCoinGovernor.deploy(
            await registry.getAddress(),
            await omniCoin.getAddress(), // token (for backwards compatibility)
            await owner.getAddress()
        );
        await governor.waitForDeployment();
        
        // Deploy test target contract for proposal actions
        const TestTarget = await ethers.getContractFactory("contracts/test/TestTarget.sol:TestTarget");
        testTarget = await TestTarget.deploy();
        await testTarget.waitForDeployment();
        
        // Fund accounts with governance tokens
        await omniCoin.mint(await proposer.getAddress(), ethers.parseUnits("2000", 6));
        await omniCoin.mint(await voter1.getAddress(), ethers.parseUnits("5000", 6));
        await omniCoin.mint(await voter2.getAddress(), ethers.parseUnits("3000", 6));
        await omniCoin.mint(await voter3.getAddress(), ethers.parseUnits("4000", 6));
        await omniCoin.mint(await voter4.getAddress(), ethers.parseUnits("1000", 6));
        
        // Fund private token holders
        await privateOmniCoin.mint(await voter1.getAddress(), ethers.parseUnits("3000", 6));
        await privateOmniCoin.mint(await voter2.getAddress(), ethers.parseUnits("2000", 6));
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await governor.owner()).to.equal(await owner.getAddress());
            expect(await governor.votingPeriod()).to.equal(DEFAULT_VOTING_PERIOD);
            expect(await governor.proposalThreshold()).to.equal(DEFAULT_PROPOSAL_THRESHOLD);
            expect(await governor.quorum()).to.equal(DEFAULT_QUORUM);
            expect(await governor.usePrivateToken()).to.be.false;
            expect(await governor.proposalCount()).to.equal(0);
        });
        
        it("Should update voting period", async function () {
            const newPeriod = 7 * 24 * 60 * 60; // 7 days
            
            await expect(governor.connect(owner).setVotingPeriod(newPeriod))
                .to.emit(governor, "VotingPeriodUpdated")
                .withArgs(DEFAULT_VOTING_PERIOD, newPeriod);
            
            expect(await governor.votingPeriod()).to.equal(newPeriod);
        });
        
        it("Should update proposal threshold", async function () {
            const newThreshold = ethers.parseUnits("500", 6);
            
            await expect(governor.connect(owner).setProposalThreshold(newThreshold))
                .to.emit(governor, "ProposalThresholdUpdated")
                .withArgs(DEFAULT_PROPOSAL_THRESHOLD, newThreshold);
            
            expect(await governor.proposalThreshold()).to.equal(newThreshold);
        });
        
        it("Should update quorum", async function () {
            const newQuorum = ethers.parseUnits("5000", 6);
            
            await expect(governor.connect(owner).setQuorum(newQuorum))
                .to.emit(governor, "QuorumUpdated")
                .withArgs(DEFAULT_QUORUM, newQuorum);
            
            expect(await governor.quorum()).to.equal(newQuorum);
        });
        
        it("Should toggle private token usage", async function () {
            expect(await governor.usePrivateToken()).to.be.false;
            
            await governor.connect(owner).setUsePrivateToken(true);
            expect(await governor.usePrivateToken()).to.be.true;
            
            // Check it uses private token
            expect(await governor.getGovernanceToken()).to.equal(await privateOmniCoin.getAddress());
        });
    });
    
    describe("Proposal Creation", function () {
        const description = "Proposal to update protocol parameters";
        
        it("Should create proposal with actions", async function () {
            const actions = [{
                target: await testTarget.getAddress(),
                value: 0,
                data: testTarget.interface.encodeFunctionData("setValue", [42])
            }];
            
            const startTime = await ethers.provider.getBlock().then(b => b.timestamp + 1);
            
            await expect(governor.connect(proposer).propose(description, actions))
                .to.emit(governor, "ProposalCreated")
                .withArgs(
                    1, // proposalId
                    await proposer.getAddress(),
                    description,
                    startTime,
                    startTime + DEFAULT_VOTING_PERIOD
                );
            
            expect(await governor.proposalCount()).to.equal(1);
            
            const proposal = await governor.getProposal(1);
            expect(proposal.id).to.equal(1);
            expect(proposal.proposer).to.equal(await proposer.getAddress());
            expect(proposal.description).to.equal(description);
            expect(proposal.executed).to.be.false;
            expect(proposal.canceled).to.be.false;
            
            // Check action was stored
            expect(await governor.getProposalActionCount(1)).to.equal(1);
            const action = await governor.getProposalAction(1, 0);
            expect(action.target).to.equal(await testTarget.getAddress());
            expect(action.value).to.equal(0);
        });
        
        it("Should create proposal with multiple actions", async function () {
            const actions = [
                {
                    target: await testTarget.getAddress(),
                    value: 0,
                    data: testTarget.interface.encodeFunctionData("setValue", [100])
                },
                {
                    target: await testTarget.getAddress(),
                    value: ethers.parseEther("0.1"),
                    data: testTarget.interface.encodeFunctionData("receiveEther")
                }
            ];
            
            await governor.connect(proposer).propose(description, actions);
            
            expect(await governor.getProposalActionCount(1)).to.equal(2);
        });
        
        it("Should reject proposal from user with insufficient balance", async function () {
            const actions = [{
                target: await testTarget.getAddress(),
                value: 0,
                data: "0x"
            }];
            
            await expect(
                governor.connect(user).propose(description, actions)
            ).to.be.revertedWithCustomError(governor, "InsufficientBalance");
        });
        
        it("Should create proposal without actions", async function () {
            await governor.connect(proposer).propose("Simple signal proposal", []);
            
            expect(await governor.getProposalActionCount(1)).to.equal(0);
        });
    });
    
    describe("Voting", function () {
        let proposalId;
        
        beforeEach(async function () {
            const actions = [{
                target: await testTarget.getAddress(),
                value: 0,
                data: testTarget.interface.encodeFunctionData("setValue", [42])
            }];
            
            const tx = await governor.connect(proposer).propose("Test proposal", actions);
            const receipt = await tx.wait();
            proposalId = 1;
        });
        
        it("Should cast vote for proposal", async function () {
            const voterBalance = await omniCoin.balanceOf(await voter1.getAddress());
            
            await expect(governor.connect(voter1).castVote(proposalId, VoteType.For))
                .to.emit(governor, "VoteCast")
                .withArgs(proposalId, await voter1.getAddress(), VoteType.For, voterBalance);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.forVotes).to.equal(voterBalance);
            expect(proposal.againstVotes).to.equal(0);
            expect(proposal.abstainVotes).to.equal(0);
            
            expect(await governor.hasVoted(proposalId, await voter1.getAddress())).to.be.true;
            expect(await governor.getVotes(proposalId, await voter1.getAddress())).to.equal(voterBalance);
        });
        
        it("Should cast vote against proposal", async function () {
            const voterBalance = await omniCoin.balanceOf(await voter2.getAddress());
            
            await governor.connect(voter2).castVote(proposalId, VoteType.Against);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.againstVotes).to.equal(voterBalance);
        });
        
        it("Should cast abstain vote", async function () {
            const voterBalance = await omniCoin.balanceOf(await voter3.getAddress());
            
            await governor.connect(voter3).castVote(proposalId, VoteType.Abstain);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.abstainVotes).to.equal(voterBalance);
        });
        
        it("Should handle multiple voters", async function () {
            await governor.connect(voter1).castVote(proposalId, VoteType.For);
            await governor.connect(voter2).castVote(proposalId, VoteType.Against);
            await governor.connect(voter3).castVote(proposalId, VoteType.For);
            await governor.connect(voter4).castVote(proposalId, VoteType.Abstain);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.forVotes).to.equal(
                await omniCoin.balanceOf(await voter1.getAddress()) +
                await omniCoin.balanceOf(await voter3.getAddress())
            );
            expect(proposal.againstVotes).to.equal(
                await omniCoin.balanceOf(await voter2.getAddress())
            );
            expect(proposal.abstainVotes).to.equal(
                await omniCoin.balanceOf(await voter4.getAddress())
            );
        });
        
        it("Should not allow double voting", async function () {
            await governor.connect(voter1).castVote(proposalId, VoteType.For);
            
            await expect(
                governor.connect(voter1).castVote(proposalId, VoteType.Against)
            ).to.be.revertedWithCustomError(governor, "AlreadyVoted");
        });
        
        it("Should not allow voting with zero balance", async function () {
            await expect(
                governor.connect(user).castVote(proposalId, VoteType.For)
            ).to.be.revertedWithCustomError(governor, "InsufficientBalance");
        });
        
        it("Should not allow voting after voting period", async function () {
            // Fast forward past voting period
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                governor.connect(voter1).castVote(proposalId, VoteType.For)
            ).to.be.revertedWithCustomError(governor, "ProposalNotActive");
        });
    });
    
    describe("Proposal Execution", function () {
        let proposalId;
        
        beforeEach(async function () {
            const actions = [{
                target: await testTarget.getAddress(),
                value: 0,
                data: testTarget.interface.encodeFunctionData("setValue", [42])
            }];
            
            await governor.connect(proposer).propose("Test proposal", actions);
            proposalId = 1;
            
            // Vote to pass the proposal
            await governor.connect(voter1).castVote(proposalId, VoteType.For);
            await governor.connect(voter2).castVote(proposalId, VoteType.For);
            await governor.connect(voter3).castVote(proposalId, VoteType.Against);
            await governor.connect(voter4).castVote(proposalId, VoteType.Abstain);
        });
        
        it("Should execute passed proposal after voting period", async function () {
            // Fast forward past voting period
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            expect(await testTarget.value()).to.equal(0);
            
            await expect(governor.connect(user).execute(proposalId))
                .to.emit(governor, "ProposalExecuted")
                .withArgs(proposalId);
            
            expect(await testTarget.value()).to.equal(42);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.executed).to.be.true;
        });
        
        it("Should not execute proposal before voting ends", async function () {
            await expect(
                governor.connect(user).execute(proposalId)
            ).to.be.revertedWithCustomError(governor, "ProposalNotActive");
        });
        
        it("Should not execute failed proposal", async function () {
            // Create a new proposal that will fail
            await governor.connect(proposer).propose("Failing proposal", []);
            const failingId = 2;
            
            // Vote against
            await governor.connect(voter1).castVote(failingId, VoteType.Against);
            await governor.connect(voter2).castVote(failingId, VoteType.Against);
            await governor.connect(voter3).castVote(failingId, VoteType.For);
            
            // Fast forward
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                governor.connect(user).execute(failingId)
            ).to.be.revertedWithCustomError(governor, "ProposalNotPassed");
        });
        
        it("Should not execute proposal without quorum", async function () {
            // Create proposal with insufficient votes
            await governor.connect(proposer).propose("Low turnout proposal", []);
            const lowTurnoutId = 2;
            
            // Only one small voter
            await governor.connect(voter4).castVote(lowTurnoutId, VoteType.For);
            
            // Fast forward
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                governor.connect(user).execute(lowTurnoutId)
            ).to.be.revertedWithCustomError(governor, "ProposalNotPassed");
        });
        
        it("Should not execute already executed proposal", async function () {
            // Fast forward and execute
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            await governor.connect(user).execute(proposalId);
            
            await expect(
                governor.connect(user).execute(proposalId)
            ).to.be.revertedWithCustomError(governor, "ProposalAlreadyExecuted");
        });
    });
    
    describe("Proposal Cancellation", function () {
        let proposalId;
        
        beforeEach(async function () {
            await governor.connect(proposer).propose("Test proposal", []);
            proposalId = 1;
        });
        
        it("Should cancel proposal by proposer", async function () {
            await expect(governor.connect(proposer).cancel(proposalId))
                .to.emit(governor, "ProposalCanceled")
                .withArgs(proposalId);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.canceled).to.be.true;
        });
        
        it("Should not allow non-proposer to cancel", async function () {
            await expect(
                governor.connect(voter1).cancel(proposalId)
            ).to.be.revertedWithCustomError(governor, "ProposalNotFound");
        });
        
        it("Should not cancel already executed proposal", async function () {
            // Vote and execute
            await governor.connect(voter1).castVote(proposalId, VoteType.For);
            await governor.connect(voter2).castVote(proposalId, VoteType.For);
            await governor.connect(voter3).castVote(proposalId, VoteType.For);
            
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            await governor.connect(user).execute(proposalId);
            
            await expect(
                governor.connect(proposer).cancel(proposalId)
            ).to.be.revertedWithCustomError(governor, "ProposalAlreadyExecuted");
        });
        
        it("Should not vote on canceled proposal", async function () {
            await governor.connect(proposer).cancel(proposalId);
            
            await expect(
                governor.connect(voter1).castVote(proposalId, VoteType.For)
            ).to.be.revertedWithCustomError(governor, "ProposalNotPending");
        });
        
        it("Should not execute canceled proposal", async function () {
            await governor.connect(voter1).castVote(proposalId, VoteType.For);
            await governor.connect(voter2).castVote(proposalId, VoteType.For);
            
            await governor.connect(proposer).cancel(proposalId);
            
            await ethers.provider.send("evm_increaseTime", [DEFAULT_VOTING_PERIOD + 1]);
            await ethers.provider.send("evm_mine");
            
            await expect(
                governor.connect(user).execute(proposalId)
            ).to.be.revertedWithCustomError(governor, "ProposalNotPending");
        });
    });
    
    describe("Private Token Governance", function () {
        beforeEach(async function () {
            // Switch to private token governance
            await governor.connect(owner).setUsePrivateToken(true);
        });
        
        it("Should use private token for proposals", async function () {
            // User with private tokens can propose
            await governor.connect(voter1).propose("Private token proposal", []);
            
            // User without private tokens cannot
            await expect(
                governor.connect(voter3).propose("Should fail", [])
            ).to.be.revertedWithCustomError(governor, "InsufficientBalance");
        });
        
        it("Should use private token balances for voting", async function () {
            await governor.connect(voter1).propose("Private voting test", []);
            const proposalId = 1;
            
            // Vote with private token holders
            await governor.connect(voter1).castVote(proposalId, VoteType.For);
            await governor.connect(voter2).castVote(proposalId, VoteType.Against);
            
            const proposal = await governor.getProposal(proposalId);
            expect(proposal.forVotes).to.equal(await privateOmniCoin.balanceOf(await voter1.getAddress()));
            expect(proposal.againstVotes).to.equal(await privateOmniCoin.balanceOf(await voter2.getAddress()));
            
            // User without private tokens cannot vote
            await expect(
                governor.connect(voter3).castVote(proposalId, VoteType.For)
            ).to.be.revertedWithCustomError(governor, "InsufficientBalance");
        });
    });
    
    describe("Access Control", function () {
        it("Should only allow owner to update voting period", async function () {
            await expect(
                governor.connect(user).setVotingPeriod(1 * 24 * 60 * 60)
            ).to.be.revertedWithCustomError(governor, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to update proposal threshold", async function () {
            await expect(
                governor.connect(user).setProposalThreshold(ethers.parseUnits("500", 6))
            ).to.be.revertedWithCustomError(governor, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to update quorum", async function () {
            await expect(
                governor.connect(user).setQuorum(ethers.parseUnits("5000", 6))
            ).to.be.revertedWithCustomError(governor, "OwnableUnauthorizedAccount");
        });
        
        it("Should only allow owner to toggle private token", async function () {
            await expect(
                governor.connect(user).setUsePrivateToken(true)
            ).to.be.revertedWithCustomError(governor, "OwnableUnauthorizedAccount");
        });
    });
});