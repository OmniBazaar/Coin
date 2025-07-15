// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OmniCoinGovernor is Ownable, ReentrancyGuard {
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool canceled;
        mapping(address => bool) hasVoted;
        mapping(address => uint256) votes;
    }

    struct ProposalAction {
        address target;
        bytes data;
        uint256 value;
    }

    IERC20 public token;
    uint256 public proposalCount;
    uint256 public votingPeriod;
    uint256 public proposalThreshold;
    uint256 public quorum;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => ProposalAction[]) public proposalActions;

    event ProposalCreated(
        uint256 indexed proposalId,
        address proposer,
        string description,
        uint256 startTime,
        uint256 endTime
    );
    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event VoteCast(
        uint256 indexed proposalId,
        address voter,
        uint256 support,
        uint256 weight
    );
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event ProposalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    enum VoteType {
        Against,
        For,
        Abstain
    }

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        token = IERC20(_token);
        votingPeriod = 3 days;
        proposalThreshold = 1000 * 10 ** 18; // 1000 tokens
        quorum = 10000 * 10 ** 18; // 10000 tokens
    }

    function propose(
        string memory description,
        ProposalAction[] memory actions
    ) external nonReentrant returns (uint256) {
        require(
            token.balanceOf(msg.sender) >= proposalThreshold,
            "OmniCoinGovernor: insufficient balance"
        );

        uint256 proposalId = proposalCount++;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + votingPeriod;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.startTime = startTime;
        proposal.endTime = endTime;

        for (uint256 i = 0; i < actions.length; i++) {
            proposalActions[proposalId].push(actions[i]);
        }

        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            startTime,
            endTime
        );

        return proposalId;
    }

    function cancel(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer,
            "OmniCoinGovernor: not proposer"
        );
        require(!proposal.executed, "OmniCoinGovernor: already executed");
        require(!proposal.canceled, "OmniCoinGovernor: already canceled");

        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "OmniCoinGovernor: already executed");
        require(!proposal.canceled, "OmniCoinGovernor: canceled");
        require(
            block.timestamp >= proposal.endTime,
            "OmniCoinGovernor: voting not ended"
        );
        require(
            proposal.forVotes > proposal.againstVotes,
            "OmniCoinGovernor: proposal failed"
        );
        require(
            proposal.forVotes + proposal.againstVotes + proposal.abstainVotes >=
                quorum,
            "OmniCoinGovernor: quorum not met"
        );

        proposal.executed = true;

        ProposalAction[] storage actions = proposalActions[proposalId];
        for (uint256 i = 0; i < actions.length; i++) {
            (bool success, ) = actions[i].target.call{value: actions[i].value}(
                actions[i].data
            );
            require(success, "OmniCoinGovernor: action failed");
        }

        emit ProposalExecuted(proposalId);
    }

    function castVote(
        uint256 proposalId,
        VoteType support
    ) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "OmniCoinGovernor: already executed");
        require(!proposal.canceled, "OmniCoinGovernor: canceled");
        require(
            block.timestamp >= proposal.startTime,
            "OmniCoinGovernor: voting not started"
        );
        require(
            block.timestamp <= proposal.endTime,
            "OmniCoinGovernor: voting ended"
        );
        require(
            !proposal.hasVoted[msg.sender],
            "OmniCoinGovernor: already voted"
        );

        uint256 weight = token.balanceOf(msg.sender);
        require(weight > 0, "OmniCoinGovernor: no voting power");

        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = weight;

        if (support == VoteType.For) {
            proposal.forVotes += weight;
        } else if (support == VoteType.Against) {
            proposal.againstVotes += weight;
        } else if (support == VoteType.Abstain) {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, uint256(support), weight);
    }

    function setVotingPeriod(uint256 _period) external onlyOwner {
        emit VotingPeriodUpdated(votingPeriod, _period);
        votingPeriod = _period;
    }

    function setProposalThreshold(uint256 _threshold) external onlyOwner {
        emit ProposalThresholdUpdated(proposalThreshold, _threshold);
        proposalThreshold = _threshold;
    }

    function setQuorum(uint256 _quorum) external onlyOwner {
        emit QuorumUpdated(quorum, _quorum);
        quorum = _quorum;
    }

    function getProposal(
        uint256 proposalId
    )
        external
        view
        returns (
            uint256 id,
            address proposer,
            string memory description,
            uint256 startTime,
            uint256 endTime,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            bool executed,
            bool canceled
        )
    {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.description,
            proposal.startTime,
            proposal.endTime,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.executed,
            proposal.canceled
        );
    }

    function getProposalAction(
        uint256 proposalId,
        uint256 index
    ) external view returns (address target, bytes memory data, uint256 value) {
        ProposalAction storage action = proposalActions[proposalId][index];
        return (action.target, action.data, action.value);
    }

    function getProposalActionCount(
        uint256 proposalId
    ) external view returns (uint256) {
        return proposalActions[proposalId].length;
    }

    function hasVoted(
        uint256 proposalId,
        address voter
    ) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }

    function getVotes(
        uint256 proposalId,
        address voter
    ) external view returns (uint256) {
        return proposals[proposalId].votes[voter];
    }
}
